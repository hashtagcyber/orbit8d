import Foundation

/// Turns a tempo into a smoothly rotating orbit angle.
public struct OrbitController {
    public enum Bars: Equatable {
        /// Picks a power-of-two bar count that keeps the orbit within `comfortablePeriod`.
        case auto
        case fixed(Int)
    }

    public static let comfortablePeriod = 8.0...20.0
    public static let fallbackPeriod = 12.0
    public static let beatsPerBar = 4.0

    public var bars: Bars = .auto { didSet { retarget() } }

    /// Degrees, 0..<360.
    public private(set) var angle = 0.0
    /// Seconds per orbit the controller is easing toward.
    public private(set) var targetPeriod = OrbitController.fallbackPeriod

    private var bpm: Double?
    private var velocity = 360 / OrbitController.fallbackPeriod
    /// Seconds for the rotation speed to settle after a tempo change.
    private let easeTime = 2.0

    public init() {}

    public static func period(bpm: Double?, bars: Bars) -> Double {
        guard let bpm, bpm > 0 else { return fallbackPeriod }
        let barSeconds = beatsPerBar * 60 / bpm
        switch bars {
        case .fixed(let count):
            return barSeconds * Double(max(1, count))
        case .auto:
            var period = barSeconds * 4
            while period < comfortablePeriod.lowerBound { period *= 2 }
            while period > comfortablePeriod.upperBound { period /= 2 }
            return period
        }
    }

    public mutating func setTempo(_ bpm: Double?) {
        self.bpm = bpm
        retarget()
    }

    /// Advances the orbit and returns the new angle. The angle never jumps.
    @discardableResult
    public mutating func advance(by dt: Double) -> Double {
        guard dt > 0 else { return angle }
        let target = 360 / targetPeriod
        velocity += (target - velocity) * (1 - exp(-dt / easeTime))
        angle = (angle + velocity * dt).truncatingRemainder(dividingBy: 360)
        return angle
    }

    private mutating func retarget() {
        targetPeriod = Self.period(bpm: bpm, bars: bars)
    }
}
