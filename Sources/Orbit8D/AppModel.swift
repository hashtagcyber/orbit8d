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
        didSet { orbit.bars = bars == 0 ? .auto : .fixed(bars) }
    }
    @Published var width = 30.0 {
        didSet { engine?.setWidth(width) }
    }
    @Published var reverb = 0.15 {
        didSet { engine?.setReverb(reverb) }
    }
    @Published private(set) var bpm: Double?
    @Published private(set) var errorMessage: String?

    var orbitPeriod: Double { orbit.targetPeriod }

    private var orbit = OrbitController()
    private var tap: SystemAudioTap?
    private var engine: SpatialEngine?
    private var tempo: TempoEstimator?
    private var orbitTimer: Timer?
    private var tempoTimer: Timer?
    private var lastTick = 0.0
    private var missedEstimates = 0
    private var pendingRestart: DispatchWorkItem?
    private var configurationObserver: NSObjectProtocol?
    private let analysisQueue = DispatchQueue(label: "orbit8d.tempo", qos: .utility)

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
            let ring = StereoRingBuffer(capacityFrames: 96_000)
            let feeder = StereoFeeder(ring: ring, primeFrames: 4_800)

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
            startTimers()
        } catch {
            stop()
            errorMessage = error.localizedDescription
            enabled = false
        }
    }

    private func stop() {
        orbitTimer?.invalidate()
        tempoTimer?.invalidate()
        orbitTimer = nil
        tempoTimer = nil
        tap?.stop()
        engine?.stop()
        tap = nil
        engine = nil
        tempo = nil
        bpm = nil
        missedEstimates = 0
        orbit.setTempo(nil)
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

    private func startTimers() {
        lastTick = ProcessInfo.processInfo.systemUptime
        let orbitTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        let tempoTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.analyze() }
        // Common modes keep the orbit moving while the menu bar panel is open.
        RunLoop.main.add(orbitTimer, forMode: .common)
        RunLoop.main.add(tempoTimer, forMode: .common)
        self.orbitTimer = orbitTimer
        self.tempoTimer = tempoTimer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        engine?.setOrbitAngle(orbit.advance(by: now - lastTick))
        lastTick = now
    }

    private func analyze() {
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
        orbit.setTempo(bpm)
    }
}
