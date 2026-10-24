import AVFoundation
import OpenWisprCore

enum CaptureError: LocalizedError {
    case microphoneDenied
    case noInput
    case systemAudio(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Allow OpenWispr in System Settings → Privacy & Security → Microphone."
        case .noInput: "No microphone is available."
        case let .systemAudio(message): message
        }
    }
}

enum MicrophonePermission {
    static var granted: Bool { AVAudioApplication.shared.recordPermission == .granted }
    static var undetermined: Bool { AVAudioApplication.shared.recordPermission == .undetermined }

    static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

/// Converts any PCM stream to 16 kHz mono Float32, keeping resampler state across buffers.
final class Resampler {
    private let converter: AVAudioConverter
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(speechSampleRate), channels: 1, interleaved: false)!

    init(from format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: format, to: target) else { throw CaptureError.noInput }
        converter.downmix = true
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// The tap delivers buffers one at a time on its own thread, so the resampler is never used concurrently.
private final class SendableResampler: @unchecked Sendable {
    private let resampler: Resampler

    init(_ resampler: Resampler) { self.resampler = resampler }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] { resampler.convert(buffer) }
}

/// Re-slices a stream into fixed-size frames, like the original's 1024-sample capture worklet.
struct FrameBatcher {
    static let frameSize = 1024
    private var pending: [Float] = []

    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var frames: [[Float]] = []
        while pending.count >= Self.frameSize {
            frames.append(Array(pending.prefix(Self.frameSize)))
            pending.removeFirst(Self.frameSize)
        }
        return frames
    }

    mutating func drain() -> [Float] {
        defer { pending = [] }
        return pending
    }
}

/// The selected microphone as 16 kHz mono samples, delivered on the audio engine's tap thread.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()

    func start(deviceUid: String, onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        guard MicrophonePermission.granted else { throw CaptureError.microphoneDenied }
        let input = engine.inputNode
        if let device = AudioDevices.deviceId(forUid: deviceUid) ?? AudioDevices.defaultInput() {
            input.withAUAudioUnit { unit in try? unit.setDeviceID(device) }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        let resampler = SendableResampler(try Resampler(from: format))
        try input.installAudioTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onSamples(resampler.convert(AVAudioPCMBuffer(copying: buffer)))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
