import AudioToolbox
import CoreAudio
import Foundation

enum TapError: LocalizedError {
    case coreAudio(String, OSStatus)
    case noProcessObject
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status): return "\(step) failed (\(status))"
        case .noProcessObject: return "Could not find this app's audio process"
        case .unsupportedFormat: return "System audio is not 32-bit float"
        }
    }
}

/// Captures all system audio except this app's, and mutes the originals while running.
final class SystemAudioTap {
    typealias Handler = (
        _ left: UnsafePointer<Float>, _ leftStride: Int,
        _ right: UnsafePointer<Float>, _ rightStride: Int,
        _ frames: Int
    ) -> Void

    private(set) var sampleRate: Double = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "orbit8d.tap", qos: .userInteractive)

    deinit { stop() }

    /// Creates the tap and its aggregate device. `sampleRate` is valid afterwards.
    func prepare() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [try ownProcessObject()])
        description.uuid = UUID()
        description.name = "Orbit8D"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create tap")

        var format = AudioStreamBasicDescription()
        try check(readProperty(tapID, kAudioTapPropertyFormat, into: &format), "Read tap format")
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { throw TapError.unsupportedFormat }
        sampleRate = format.mSampleRate

        // The output device is the aggregate's clock, so capture and playback cannot drift apart.
        let outputUID = try defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Orbit8D Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create aggregate device")
    }

    /// Starts delivering audio. The handler runs on the capture thread.
    func run(handler: @escaping Handler) throws {
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }

            // Tap streams come after any input streams of the output device (a headset mic, say).
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let last = buffers.last, let data = last.mData else { return }
            let samples = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            let channels = Int(last.mNumberChannels)
            guard channels > 0 else { return }
            let frames = Int(last.mDataByteSize) / (MemoryLayout<Float>.size * channels)

            if channels >= 2 {
                handler(samples, channels, samples + 1, channels, frames)
            } else if buffers.count >= 2, let leftData = buffers[buffers.count - 2].mData {
                handler(UnsafePointer(leftData.assumingMemoryBound(to: Float.self)), 1, samples, 1, frames)
            } else {
                handler(samples, 1, samples, 1, frames)
            }
        }
        try check(status, "Create IO proc")
        try check(AudioDeviceStart(aggregateID, ioProcID), "Start capture")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func ownProcessObject() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject)
        try check(status, "Find own process")
        // Tapping without excluding ourselves would capture and mute our own output.
        guard processObject != kAudioObjectUnknown else { throw TapError.noProcessObject }
        return processObject
    }

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try check(
            readProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &deviceID),
            "Find output device")
        var uid = "" as CFString
        try check(readProperty(deviceID, kAudioDevicePropertyDeviceUID, into: &uid), "Read output device UID")
        return uid as String
    }
}

private func readProperty<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> OSStatus {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw TapError.coreAudio(step, status) }
}
