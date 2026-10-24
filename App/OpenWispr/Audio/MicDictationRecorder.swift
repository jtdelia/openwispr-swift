import Foundation
import OpenWisprCore
import Synchronization

/// Records one dictation from the selected microphone and hands the WAV to the controller.
@Observable
@MainActor
final class MicDictationRecorder: DictationRecorder {
    @ObservationIgnored weak var controller: DictationController?
    private(set) var level: Float = 0

    @ObservationIgnored private var capture: MicrophoneCapture?
    @ObservationIgnored private var buffer = SampleBuffer()
    @ObservationIgnored private var generation = 0

    func start(deviceId: String) {
        teardown()
        let generation = self.generation
        Task {
            if MicrophonePermission.undetermined { _ = await MicrophonePermission.request() }
            guard generation == self.generation else { return }
            let capture = MicrophoneCapture()
            let buffer = SampleBuffer()
            do {
                try capture.start(deviceUid: deviceId) { samples in
                    let level = buffer.append(samples)
                    Task { @MainActor in self.level = level }
                }
            } catch {
                controller?.recorderFailed(error.localizedDescription)
                return
            }
            self.capture = capture
            self.buffer = buffer
            controller?.recorderStarted()
        }
    }

    func stop() {
        let samples = buffer.take()
        teardown()
        let wav = encodeWav(samples: samples)
        Task { await controller?.handleAudio(wav) }
    }

    func cancel() {
        teardown()
    }

    private func teardown() {
        generation += 1
        capture?.stop()
        capture = nil
        buffer = SampleBuffer()
        level = 0
    }
}

/// Collects samples from the tap thread; reports the input level as RMS × 6, like the original.
final class SampleBuffer: Sendable {
    private let samples = Mutex<[Float]>([])

    func append(_ chunk: [Float]) -> Float {
        samples.withLock { $0.append(contentsOf: chunk) }
        guard !chunk.isEmpty else { return 0 }
        let sum = chunk.reduce(Float(0)) { $0 + $1 * $1 }
        return min(1, (sum / Float(chunk.count)).squareRoot() * 6)
    }

    func take() -> [Float] {
        samples.withLock { value in
            defer { value = [] }
            return value
        }
    }
}
