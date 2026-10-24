import Foundation
import OpenWisprCore

/// Records the microphone and system audio as two separate 16 kHz streams, so the transcript can tell
/// the user apart from everyone else, and hands back speech chunks as they complete.
@MainActor
final class MeetingAudioRecorder: MeetingRecorder {
    weak var controller: NotetakerController?

    private var pipeline: MeetingPipeline?
    private var mic: MicrophoneCapture?
    private var system: SystemAudioTap?
    private var activeSession: Int?

    func start(session: Int, deviceId: String) {
        stopCaptures()
        activeSession = session
        Task {
            if MicrophonePermission.undetermined { _ = await MicrophonePermission.request() }
            guard activeSession == session else { return }
            // Chunks and the stop report both hop to the main queue, which is FIFO, so the last chunk
            // always reaches the controller before it hears the recording has flushed.
            let pipeline = MeetingPipeline(session: session, startedAt: epochMs()) { chunk in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.controller?.handleChunk(chunk) } }
            }
            let mic = MicrophoneCapture()
            do {
                pipeline.add(.mic)
                try mic.start(deviceUid: deviceId) { pipeline.push(.mic, $0) }
            } catch {
                controller?.recorderFailed(session: session, message: error.localizedDescription)
                return
            }
            var systemAudioError: String?
            let system = SystemAudioTap()
            do {
                pipeline.add(.system)
                try system.start { pipeline.push(.system, $0) }
                self.system = system
            } catch {
                pipeline.remove(.system)
                systemAudioError = error.localizedDescription
            }
            self.mic = mic
            self.pipeline = pipeline
            controller?.recorderStarted(session: session, systemAudioError: systemAudioError)
        }
    }

    /// Emits the final partial chunks, then reports that the recording has flushed.
    func stop(session: Int) {
        if activeSession == session { activeSession = nil }
        guard let pipeline, pipeline.session == session else {
            controller?.recorderStopped(session: session)
            return
        }
        stopCaptures()
        pipeline.finish { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.controller?.recorderStopped(session: session) } }
        }
    }

    func cut(session: Int, source: TranscriptSource) {
        guard let pipeline, pipeline.session == session else { return }
        pipeline.cut(source)
    }

    private func stopCaptures() {
        mic?.stop()
        system?.stop()
        mic = nil
        system = nil
        pipeline = nil
    }
}

/// Chunking and echo gating for one recording, confined to its own serial queue.
final class MeetingPipeline: @unchecked Sendable {
    private struct Capture {
        var chunker = SpeechChunker(ChunkerOptions(sampleRate: speechSampleRate))
        var batcher = FrameBatcher()
        /// Ms after the session started that this capture's first sample was recorded.
        var offsetMs: Double
        /// `offsetMs` in samples, so both captures share one sample clock for echo detection.
        var offsetSamples: Int
        var receivedSamples = 0
    }

    let session: Int
    private let startedAt: Double
    private let onChunk: @Sendable (MeetingChunk) -> Void
    private let queue = DispatchQueue(label: "openwispr.meeting-pipeline", qos: .userInitiated)
    private let echo = EchoDetector(EchoDetectorConfig())
    private let gate: EchoGate
    private var captures: [TranscriptSource: Capture] = [:]
    private var finished = false

    init(session: Int, startedAt: Double, onChunk: @escaping @Sendable (MeetingChunk) -> Void) {
        self.session = session
        self.startedAt = startedAt
        self.onChunk = onChunk
        gate = EchoGate(detector: echo, sampleRate: speechSampleRate)
    }

    func add(_ source: TranscriptSource) {
        let offsetMs = epochMs() - startedAt
        queue.async {
            self.captures[source] = Capture(offsetMs: offsetMs, offsetSamples: msToSamples(offsetMs, sampleRate: speechSampleRate))
        }
    }

    func remove(_ source: TranscriptSource) {
        queue.async { self.captures[source] = nil }
    }

    func push(_ source: TranscriptSource, _ samples: [Float]) {
        queue.async {
            guard !self.finished, var capture = self.captures[source] else { return }
            for frame in capture.batcher.append(samples) { self.process(source, frame, &capture) }
            self.captures[source] = capture
        }
    }

    func cut(_ source: TranscriptSource) {
        queue.async { self.captures[source]?.chunker.requestCut() }
    }

    func finish(_ done: @escaping @Sendable () -> Void) {
        queue.async {
            self.finished = true
            for source in [TranscriptSource.mic, .system] {
                guard var capture = self.captures[source] else { continue }
                let rest = capture.batcher.drain()
                if !rest.isEmpty { self.process(source, rest, &capture) }
                if let chunk = capture.chunker.flush() { self.emit(source, chunk, capture) }
                self.captures[source] = capture
            }
            self.gate.flush()
            done()
        }
    }

    private func process(_ source: TranscriptSource, _ frame: [Float], _ capture: inout Capture) {
        echo.push(source, frame, at: capture.offsetSamples + capture.receivedSamples)
        capture.receivedSamples += frame.count
        if let chunk = capture.chunker.push(frame) { emit(source, chunk, capture) }
        releaseDecidedMic()
    }

    private func emit(_ source: TranscriptSource, _ chunk: SpeechChunk, _ capture: Capture) {
        switch source {
        case .mic:
            let start = capture.offsetSamples + chunk.startSample
            let end = capture.offsetSamples + chunk.endSample
            gate.hold(HeldChunk(start: start, end: end, samples: chunk.samples) { samples in
                self.send(source, chunk, capture, samples: samples)
            })
            releaseDecidedMic()
        case .system:
            send(source, chunk, capture, samples: chunk.samples)
        }
    }

    /// While stopping, held chunks wait for `finish` to flush them after every capture's last frames.
    private func releaseDecidedMic() {
        guard !finished else { return }
        gate.releaseDecided(systemLive: captures[.system] != nil)
    }

    private func send(_ source: TranscriptSource, _ chunk: SpeechChunk, _ capture: Capture, samples: [Float]) {
        let startMs = capture.offsetMs + capture.chunker.msAt(chunk.startSample)
        onChunk(MeetingChunk(
            session: session,
            source: source,
            startMs: startMs,
            endMs: capture.offsetMs + capture.chunker.msAt(chunk.endSample),
            wallClockMs: startedAt + startMs,
            wav: encodeWav(samples: samples)
        ))
    }
}
