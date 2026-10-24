import Foundation
import OpenWisprCore

/// Launch argument that swaps the microphone, models and Accessibility for deterministic fakes and keeps
/// data in a throwaway folder, so XCUITest can drive every flow.
let uiTestingArgument = "--ui-testing"

enum UITestSpeech {
    static let dictation = "Hello from the UI test."
    static let mic = "Let's ship the beta on Friday once the last onboarding bugs are fixed and QA signs off."
    static let system = "Sounds good, I will update the docs by Thursday and send the release notes to everyone."
    static let title = "Beta launch planning"
    static let summary = """
    ### Summary
    The team agreed to ship the beta on Friday.

    ### Action Items
    - [ ] **Alice Smith**: update the docs by Thursday
    """

    /// The fakes tell recordings apart by length: dictations are 1 s, mic chunks 2 s, call audio 3 s.
    static func text(forSeconds seconds: Double) -> String {
        switch seconds {
        case ..<1.5: dictation
        case ..<2.5: mic
        default: system
        }
    }

    static func tone(seconds: Double) -> Data {
        let count = Int(seconds * Double(speechSampleRate))
        let samples = (0..<count).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / Double(speechSampleRate))) }
        return encodeWav(samples: samples)
    }
}

struct UITestEngines: BuiltInEngines {
    func transcribe(model: String, wav: Data, language: String, prompt: String, segments: Bool) async throws -> EngineTranscription {
        let seconds = (try? decodeWav(wav)).map { Double($0.samples.count) / Double($0.sampleRate) } ?? 0
        let text = UITestSpeech.text(forSeconds: seconds)
        return EngineTranscription(text: text, segments: segments ? [.init(start: 0, end: seconds, text: text)] : nil)
    }

    func complete(model: String, messages: [ChatMessage], maxTokens: Int) async throws -> String {
        let system = messages.first?.content ?? ""
        if system.hasPrefix("You name meetings") { return UITestSpeech.title }
        if system.contains("### Summary") { return UITestSpeech.summary }
        let user = messages.last?.content ?? ""
        guard let start = user.range(of: "<transcript>\n"), let end = user.range(of: "\n</transcript>", range: start.upperBound..<user.endIndex) else {
            return user
        }
        return String(user[start.upperBound..<end.lowerBound])
    }

    func load(_ models: [ModelRef]) async throws {}
    func unload(_ models: [String]) async throws {}

    func status(language: String, speechToText: String?, chat: String?) async throws -> BuiltInStatus {
        BuiltInStatus(
            appleSpeech: .init(available: true, locale: "en-US", locales: ["en-US", "de-DE", "fr-FR"]),
            appleChat: .init(available: true, contextSize: 4096)
        )
    }

    func stop() async {}
}

@Observable
@MainActor
final class UITestDictationRecorder: DictationRecorder {
    @ObservationIgnored weak var controller: DictationController?
    private(set) var level: Float = 0
    @ObservationIgnored private var meter: Task<Void, Never>?

    func start(deviceId: String) {
        controller?.recorderStarted()
        meter = Task {
            var phase: Float = 0
            while !Task.isCancelled {
                phase += 0.7
                level = 0.35 + 0.3 * sin(phase)
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    func stop() {
        teardown()
        Task { await controller?.handleAudio(UITestSpeech.tone(seconds: 1)) }
    }

    func cancel() {
        teardown()
    }

    private func teardown() {
        meter?.cancel()
        meter = nil
        level = 0
    }
}

@MainActor
final class UITestMeetingRecorder: MeetingRecorder {
    weak var controller: NotetakerController?
    private var feed: Task<Void, Never>?

    func start(session: Int, deviceId: String) {
        controller?.recorderStarted(session: session, systemAudioError: nil)
        feed = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let now = epochMs()
            controller?.handleChunk(MeetingChunk(session: session, source: .mic, startMs: 0, endMs: 2000, wallClockMs: now, wav: UITestSpeech.tone(seconds: 2)))
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            controller?.handleChunk(MeetingChunk(
                session: session, source: .system, startMs: 2500, endMs: 5500, wallClockMs: now + 2500, wav: UITestSpeech.tone(seconds: 3)
            ))
        }
    }

    func stop(session: Int) {
        feed?.cancel()
        feed = nil
        controller?.recorderStopped(session: session)
    }

    func cut(session: Int, source: TranscriptSource) {}
}

@MainActor
final class UITestSpeakers: SpeakerDetector {
    func startPolling(markers: MeetTileMarkers, report: @escaping @MainActor (SpeakersReport) -> Void) {
        report(SpeakersReport(platform: .meet, speaking: ["Alice Smith"], timestamp: epochMs()))
    }

    func stopPolling() {}
}
