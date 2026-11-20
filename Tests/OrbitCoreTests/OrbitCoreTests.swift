import XCTest
@testable import OrbitCore

final class TempoEstimatorTests: XCTestCase {
    private func clickTrack(bpm: Double, seconds: Double, sampleRate: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let clickLength = Int(0.005 * sampleRate)
        var beat = 0.0
        while beat < seconds {
            let start = Int(beat * sampleRate)
            for i in 0..<clickLength where start + i < samples.count {
                samples[start + i] = 0.8 * sin(Float(i) * 0.6)
            }
            beat += 60 / bpm
        }
        return samples
    }

    func testFindsClickTrackTempo() {
        for bpm in [90.0, 120.0, 150.0] {
            let estimator = TempoEstimator(sampleRate: 48_000)
            estimator.process(mono: clickTrack(bpm: bpm, seconds: 15, sampleRate: 48_000))
            let estimate = estimator.estimate()
            XCTAssertNotNil(estimate, "\(bpm) BPM")
            XCTAssertEqual(estimate?.bpm ?? 0, bpm, accuracy: 3, "\(bpm) BPM")
        }
    }

    func testSilenceHasNoTempo() {
        let estimator = TempoEstimator(sampleRate: 48_000)
        estimator.process(mono: [Float](repeating: 0, count: 48_000 * 10))
        XCTAssertNil(estimator.estimate())
    }

    func testNeedsSixSeconds() {
        let estimator = TempoEstimator(sampleRate: 48_000)
        estimator.process(mono: clickTrack(bpm: 120, seconds: 3, sampleRate: 48_000))
        XCTAssertNil(estimator.estimate())
    }
}

final class OrbitControllerTests: XCTestCase {
    func testAutoKeepsPeriodComfortable() {
        XCTAssertEqual(OrbitController.period(bpm: 120, bars: .auto), 8, accuracy: 0.001)
        XCTAssertEqual(OrbitController.period(bpm: 150, bars: .auto), 12.8, accuracy: 0.001)
        XCTAssertEqual(OrbitController.period(bpm: 90, bars: .auto), 10.667, accuracy: 0.001)
        for bpm in stride(from: 60.0, through: 180.0, by: 1) {
            XCTAssertTrue(OrbitController.comfortablePeriod.contains(OrbitController.period(bpm: bpm, bars: .auto)))
        }
    }

    func testFixedBarsAndFallback() {
        XCTAssertEqual(OrbitController.period(bpm: 120, bars: .fixed(8)), 16, accuracy: 0.001)
        XCTAssertEqual(OrbitController.period(bpm: nil, bars: .fixed(8)), OrbitController.fallbackPeriod)
    }

    func testAngleNeverJumpsOnTempoChange() {
        var orbit = OrbitController()
        var previous = orbit.angle
        for step in 0..<600 {
            if step == 300 { orbit.setTempo(170) }
            let angle = orbit.advance(by: 1.0 / 60)
            let delta = (angle - previous + 360).truncatingRemainder(dividingBy: 360)
            XCTAssertLessThan(delta, 2)
            previous = angle
        }
    }
}

final class StereoFeederTests: XCTestCase {
    func testChannelsStayAlignedAcrossUnevenPulls() {
        let ring = StereoRingBuffer(capacityFrames: 4_096)
        let feeder = StereoFeeder(ring: ring, primeFrames: 0)
        // Left carries n, right carries -n, so alignment is checkable sample by sample.
        let ramp = (0..<2_000).map(Float.init)
        let negated = ramp.map { -$0 }
        ring.write(left: ramp, leftStride: 1, right: negated, rightStride: 1, frames: ramp.count)

        var left = [Float](repeating: 0, count: 1_000)
        var right = [Float](repeating: 0, count: 1_000)
        feeder.render(channel: 0, into: &left, frames: 300)
        feeder.render(channel: 1, into: &right, frames: 1_000)
        left.withUnsafeMutableBufferPointer { feeder.render(channel: 0, into: $0.baseAddress! + 300, frames: 700) }

        XCTAssertEqual(left, Array(ramp[0..<1_000]))
        XCTAssertEqual(right, Array(negated[0..<1_000]))
    }

    func testUnderrunPlaysSilenceOnBothChannels() {
        let ring = StereoRingBuffer(capacityFrames: 1_024)
        let feeder = StereoFeeder(ring: ring, primeFrames: 256)
        var left = [Float](repeating: 1, count: 128)
        var right = [Float](repeating: 1, count: 128)
        feeder.render(channel: 0, into: &left, frames: 128)
        feeder.render(channel: 1, into: &right, frames: 128)
        XCTAssertEqual(left, [Float](repeating: 0, count: 128))
        XCTAssertEqual(right, [Float](repeating: 0, count: 128))
    }
}
