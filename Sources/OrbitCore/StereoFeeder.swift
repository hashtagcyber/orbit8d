import Foundation

/// Hands the ring buffer's audio to two mono render callbacks, one per channel.
///
/// Each callback pulls independently, so the feeder stages frames for both channels at once
/// and keeps them sample-aligned whatever order or block size the callbacks use.
/// Call `render` from the render thread only.
public final class StereoFeeder {
    private let ring: StereoRingBuffer
    private let primeFrames: Int
    private let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var fill = 0
    private var leftPosition = 0
    private var rightPosition = 0
    private var primed = false

    /// - Parameter primeFrames: frames to accumulate before playback starts or resumes after an underrun.
    public init(ring: StereoRingBuffer, primeFrames: Int, capacity: Int = 16_384) {
        self.ring = ring
        self.primeFrames = primeFrames
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    public func render(channel: Int, into output: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames <= capacity else {
            output.update(repeating: 0, count: frames)
            return
        }
        let isLeft = channel == 0
        if (isLeft ? leftPosition : rightPosition) + frames > fill { compact() }
        if (isLeft ? leftPosition : rightPosition) + frames > capacity {
            // The other channel stopped pulling; drop its backlog.
            fill = 0
            leftPosition = 0
            rightPosition = 0
        }
        let position = isLeft ? leftPosition : rightPosition
        if position + frames > fill { pull(position + frames - fill) }
        output.update(from: (isLeft ? left : right) + position, count: frames)
        if isLeft { leftPosition += frames } else { rightPosition += frames }
    }

    private func compact() {
        let consumed = min(leftPosition, rightPosition)
        guard consumed > 0 else { return }
        let remaining = fill - consumed
        left.update(from: left + consumed, count: remaining)
        right.update(from: right + consumed, count: remaining)
        fill = remaining
        leftPosition -= consumed
        rightPosition -= consumed
    }

    private func pull(_ frames: Int) {
        if !primed { primed = ring.availableFrames >= primeFrames }
        var got = 0
        if primed {
            got = ring.read(left: left + fill, right: right + fill, frames: frames)
            if got < frames { primed = false }
        }
        (left + fill + got).update(repeating: 0, count: frames - got)
        (right + fill + got).update(repeating: 0, count: frames - got)
        fill += frames
    }
}
