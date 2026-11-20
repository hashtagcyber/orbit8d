import Foundation
import os

/// FIFO of stereo frames shared between the capture thread (writer) and the render thread (reader).
public final class StereoRingBuffer {
    private let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var readIndex = 0
    private var count = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    public init(capacityFrames: Int) {
        capacity = capacityFrames
        left = .allocate(capacity: capacityFrames)
        right = .allocate(capacity: capacityFrames)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        left.deallocate()
        right.deallocate()
        lock.deallocate()
    }

    public var availableFrames: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return count
    }

    /// Frames that do not fit are dropped.
    public func write(
        left source: UnsafePointer<Float>, leftStride: Int,
        right otherSource: UnsafePointer<Float>, rightStride: Int,
        frames: Int
    ) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let n = min(frames, capacity - count)
        var index = (readIndex + count) % capacity
        for i in 0..<n {
            left[index] = source[i * leftStride]
            right[index] = otherSource[i * rightStride]
            index += 1
            if index == capacity { index = 0 }
        }
        count += n
    }

    /// Returns the number of frames read, which is less than `frames` on underrun.
    public func read(left destination: UnsafeMutablePointer<Float>, right otherDestination: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let n = min(frames, count)
        for i in 0..<n {
            destination[i] = left[readIndex]
            otherDestination[i] = right[readIndex]
            readIndex += 1
            if readIndex == capacity { readIndex = 0 }
        }
        count -= n
        return n
    }
}
