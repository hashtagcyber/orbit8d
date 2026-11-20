import AVFoundation
import CoreAudio
import Foundation
import OrbitCore

/// Owns the capture → spatialize pipeline. Use from the main thread.
final class AppModel: ObservableObject {
    @Published var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { start() } else { stop() }
        }
    }
    /// Bars per orbit; 0 picks automatically.
    @Published var bars = 0 {
        didSet {
            let bars = barsSetting
            orbitQueue.async { [weak self] in self?.orbit.bars = bars }
        }
    }
    @Published var width = 30.0 {
        didSet { engine?.setWidth(width) }
    }
    @Published var reverb = 0.15 {
        didSet { engine?.setReverb(reverb) }
    }
    @Published private(set) var bpm: Double?
    @Published private(set) var dropouts = 0
    @Published private(set) var errorMessage: String?
    /// Set when audio arrives at a different rate than it is played, which causes dropouts.
    @Published private(set) var rateWarning: String?

    private var lastRateCheck = 0.0
    private var lastFrameCount = 0
    private var measuredRate = 0.0

    var orbitPeriod: Double { OrbitController.period(bpm: bpm, bars: barsSetting) }

    private var barsSetting: OrbitController.Bars { bars == 0 ? .auto : .fixed(bars) }

    private var tap: SystemAudioTap?
    private var engine: SpatialEngine?
    private var feeder: StereoFeeder?
    private var tempo: TempoEstimator?
    private var tempoTimer: Timer?
    private var missedEstimates = 0
    private var pendingRestart: DispatchWorkItem?
    private var configurationObserver: NSObjectProtocol?
    private let analysisQueue = DispatchQueue(label: "orbit8d.tempo", qos: .utility)

    // The orbit runs off the main thread so UI work cannot make the motion stutter.
    private let orbitQueue = DispatchQueue(label: "orbit8d.orbit", qos: .userInteractive)
    private var orbit = OrbitController()
    private var orbitTimer: DispatchSourceTimer?
    private var lastTick = 0.0

    init() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.scheduleRestart()
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRestart()
        }
    }

    private func start() {
        errorMessage = nil
        do {
            // Half a second of cushion: capture arrives in bursts, and delay does not matter here.
            let ring = StereoRingBuffer(capacityFrames: 192_000)
            let feeder = StereoFeeder(ring: ring, primeFrames: 24_000)
            self.feeder = feeder

            // The engine starts first so this process exists in Core Audio and the tap can exclude it.
            var engine = try SpatialEngine(feeder: feeder)
            self.engine = engine
            let tap = SystemAudioTap()
            self.tap = tap
            try tap.prepare()
            if tap.sampleRate != engine.sampleRate {
                engine.stop()
                engine = try SpatialEngine(feeder: feeder, sampleRate: tap.sampleRate)
                self.engine = engine
            }
            engine.setWidth(width)
            engine.setReverb(reverb)

            let tempo = TempoEstimator(sampleRate: tap.sampleRate)
            self.tempo = tempo
            try tap.run { left, leftStride, right, rightStride, frames in
                ring.write(left: left, leftStride: leftStride, right: right, rightStride: rightStride, frames: frames)
                tempo.process(left: left, leftStride: leftStride, right: right, rightStride: rightStride, frames: frames)
            }
            startTimers(engine: engine)
        } catch {
            stop()
            errorMessage = error.localizedDescription
            enabled = false
        }
    }

    private func stop() {
        orbitTimer?.cancel()
        orbitTimer = nil
        tempoTimer?.invalidate()
        tempoTimer = nil
        tap?.stop()
        engine?.stop()
        tap = nil
        engine = nil
        feeder = nil
        tempo = nil
        bpm = nil
        dropouts = 0
        rateWarning = nil
        lastRateCheck = 0
        measuredRate = 0
        missedEstimates = 0
        orbitQueue.async { [weak self] in self?.orbit.setTempo(nil) }
    }

    /// Rebuilds the pipeline after the output device changes. Both triggers can fire for one change.
    private func scheduleRestart() {
        guard enabled else { return }
        pendingRestart?.cancel()
        let restart = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            self.stop()
            self.start()
        }
        pendingRestart = restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: restart)
    }

    private func startTimers(engine: SpatialEngine) {
        let orbitTimer = DispatchSource.makeTimerSource(queue: orbitQueue)
        orbitTimer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        orbitTimer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            // Capped so a late tick cannot swing the sound across the head.
            let dt = self.lastTick == 0 ? 0 : min(now - self.lastTick, 0.05)
            self.lastTick = now
            engine.setOrbitAngle(self.orbit.advance(by: dt))
        }
        orbitTimer.resume()
        self.orbitTimer = orbitTimer

        let tempoTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.analyze() }
        // Common modes keep the timer firing while the menu bar panel is open.
        RunLoop.main.add(tempoTimer, forMode: .common)
        self.tempoTimer = tempoTimer
    }

    private func measureCaptureRate() {
        guard let tap else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let frames = tap.framesDelivered
        if lastRateCheck > 0, now > lastRateCheck {
            let measured = Double(frames - lastFrameCount) / (now - lastRateCheck)
            // Averaged, since a 2 s window catches a whole number of capture bursts.
            measuredRate = measuredRate == 0 ? measured : measuredRate * 0.8 + measured * 0.2
            let off = abs(measuredRate - tap.sampleRate) / tap.sampleRate
            rateWarning = off > 0.02 ? String(format: "capture %.1f kHz, expected %.1f", measuredRate / 1000, tap.sampleRate / 1000) : nil
        }
        lastRateCheck = now
        lastFrameCount = frames
    }

    private func analyze() {
        dropouts = feeder?.underruns ?? 0
        measureCaptureRate()
        guard let tempo else { return }
        analysisQueue.async { [weak self] in
            let estimate = tempo.estimate()
            DispatchQueue.main.async {
                guard let self, self.tempo === tempo else { return }
                self.apply(estimate)
            }
        }
    }

    private func apply(_ estimate: TempoEstimator.Estimate?) {
        if let estimate {
            missedEstimates = 0
            if let current = bpm, abs(estimate.bpm - current) / current < 0.08 {
                bpm = current * 0.7 + estimate.bpm * 0.3
            } else {
                bpm = estimate.bpm
            }
        } else {
            // Hold the last tempo through short gaps such as a quiet bridge.
            missedEstimates += 1
            if missedEstimates >= 5 { bpm = nil }
        }
        let bpm = bpm
        orbitQueue.async { [weak self] in self?.orbit.setTempo(bpm) }
    }
}
