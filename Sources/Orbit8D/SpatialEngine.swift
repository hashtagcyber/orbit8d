import AVFoundation
import OrbitCore

enum SpatialEngineError: LocalizedError {
    case noOutputDevice

    var errorDescription: String? { "No audio output device" }
}

/// Renders the stereo feed as two HRTF-spatialized virtual speakers that orbit the listener.
final class SpatialEngine {
    let sampleRate: Double

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var sources: [AVAudioSourceNode] = []

    /// - Parameter sampleRate: rate of the audio in `feeder`; nil uses the output device's rate.
    init(feeder: StereoFeeder, sampleRate: Double? = nil) throws {
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard hardwareRate > 0,
              let stereo = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 2),
              let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate ?? hardwareRate, channels: 1)
        else { throw SpatialEngineError.noOutputDevice }
        self.sampleRate = mono.sampleRate

        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        environment.outputType = .headphones
        environment.reverbParameters.enable = true
        environment.reverbParameters.loadFactoryReverbPreset(.mediumRoom)
        // Headroom: HRTF filters boost the ear nearest each source.
        engine.mainMixerNode.outputVolume = 0.7

        // Only mono inputs are spatialized, so each channel gets its own source.
        for channel in 0..<2 {
            let source = AVAudioSourceNode(format: mono) { _, _, frameCount, bufferList in
                guard let data = UnsafeMutableAudioBufferListPointer(bufferList)[0].mData else { return noErr }
                feeder.render(channel: channel, into: data.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: environment, format: mono)
            source.renderingAlgorithm = .HRTFHQ
            sources.append(source)
        }
        setWidth(30)
        setReverb(0.15)

        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    /// Rotates the virtual speakers around the listener by turning the listener instead.
    func setOrbitAngle(_ degrees: Double) {
        let yaw = degrees > 180 ? degrees - 360 : degrees
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: Float(yaw), pitch: 0, roll: 0)
    }

    /// Half the angle between the two virtual speakers, in degrees.
    func setWidth(_ halfAngle: Double) {
        let radians = Float(halfAngle * .pi / 180)
        // The listener faces -z; +x is to the right.
        sources[0].position = AVAudio3DPoint(x: -sin(radians), y: 0, z: -cos(radians))
        sources[1].position = AVAudio3DPoint(x: sin(radians), y: 0, z: -cos(radians))
    }

    /// 0 is dry, 1 is fully reverberant.
    func setReverb(_ blend: Double) {
        for source in sources { source.reverbBlend = Float(blend) }
    }
}
