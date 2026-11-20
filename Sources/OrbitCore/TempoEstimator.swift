import Foundation

/// Estimates tempo by autocorrelating an onset-strength envelope.
///
/// `process` is called from the audio capture thread; `estimate` from anywhere else.
public final class TempoEstimator {
    public struct Estimate: Equatable {
        public let bpm: Double
        /// Autocorrelation peak relative to zero lag, 0...1.
        public let confidence: Double
    }

    public static let hop = 256

    private let envelopeRate: Double
    private let minConfidence: Double
    private let minBPM = 60.0
    private let maxBPM = 180.0

    private var onsets: [Float]
    private var writeIndex = 0
    private var filled = 0
    private let lock = NSLock()

    // Capture-thread state.
    private var hopEnergy: Float = 0
    private var hopFrames = 0
    private var previousLogEnergy: Float?

    public init(sampleRate: Double, windowSeconds: Double = 12, minConfidence: Double = 0.1) {
        envelopeRate = sampleRate / Double(Self.hop)
        self.minConfidence = minConfidence
        onsets = [Float](repeating: 0, count: max(1, Int(windowSeconds * envelopeRate)))
    }

    public func process(
        left: UnsafePointer<Float>, leftStride: Int,
        right: UnsafePointer<Float>, rightStride: Int,
        frames: Int
    ) {
        var l = left
        var r = right
        for _ in 0..<frames {
            let sample = (l.pointee + r.pointee) * 0.5
            hopEnergy += sample * sample
            hopFrames += 1
            if hopFrames == Self.hop { pushHop() }
            l += leftStride
            r += rightStride
        }
    }

    public func process(mono samples: [Float]) {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            process(left: base, leftStride: 1, right: base, rightStride: 1, frames: buffer.count)
        }
    }

    private func pushHop() {
        let logEnergy = log(hopEnergy / Float(Self.hop) + 1e-9)
        let onset = max(0, logEnergy - (previousLogEnergy ?? logEnergy))
        previousLogEnergy = logEnergy
        hopEnergy = 0
        hopFrames = 0

        lock.lock()
        onsets[writeIndex] = onset
        writeIndex = (writeIndex + 1) % onsets.count
        filled = min(filled + 1, onsets.count)
        lock.unlock()
    }

    /// Returns nil until 6 s of audio has been seen, and when no clear beat is present.
    public func estimate() -> Estimate? {
        lock.lock()
        let n = filled
        var window = [Float](repeating: 0, count: n)
        let start = (writeIndex - n + onsets.count) % onsets.count
        for i in 0..<n { window[i] = onsets[(start + i) % onsets.count] }
        lock.unlock()

        guard Double(n) >= envelopeRate * 6 else { return nil }

        let mean = window.reduce(0, +) / Float(n)
        for i in 0..<n { window[i] -= mean }

        let energy = Self.autocorrelation(window, lag: 0)
        guard energy > 1e-6 else { return nil }

        let minLag = max(2, Int(envelopeRate * 60 / maxBPM))
        let maxLag = min(n / 2, Int((envelopeRate * 60 / minBPM).rounded(.up)))
        guard maxLag > minLag else { return nil }

        // One extra lag on each side for peak interpolation.
        let r = ((minLag - 1)...(maxLag + 1)).map { Self.autocorrelation(window, lag: $0) }
        var bestIndex = 1
        var bestScore = -Double.infinity
        for index in 1..<(r.count - 1) {
            let bpm = 60 * envelopeRate / Double(minLag - 1 + index)
            // Log-normal prior around 120 BPM resolves half/double-tempo ties.
            let octaves = log2(bpm / 120) / 0.8
            let score = Double(r[index]) * exp(-0.5 * octaves * octaves)
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        let confidence = Double(r[bestIndex] / energy)
        guard confidence >= minConfidence else { return nil }

        var lag = Double(minLag - 1 + bestIndex)
        let (a, b, c) = (Double(r[bestIndex - 1]), Double(r[bestIndex]), Double(r[bestIndex + 1]))
        let curvature = a - 2 * b + c
        if curvature < 0 {
            let offset = 0.5 * (a - c) / curvature
            if abs(offset) < 1 { lag += offset }
        }
        return Estimate(bpm: 60 * envelopeRate / lag, confidence: confidence)
    }

    private static func autocorrelation(_ x: [Float], lag: Int) -> Float {
        var sum: Float = 0
        for i in lag..<x.count { sum += x[i] * x[i - lag] }
        return sum / Float(x.count - lag)
    }
}
