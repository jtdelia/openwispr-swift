import Foundation
import Testing
@testable import OpenWisprCore

private let t0 = 1_700_000_000_000.0

@MainActor
private final class Harness {
    let controller: NotetakerController
    let meetings: MeetingStore
    let meetingId: String

    init(_ settings: Settings, engines: FakeEngines = FakeEngines(), http: FakeHub = FakeHub()) async throws {
        let directory = try temporaryDirectory()
        let store = DataStore(directory: directory, secrets: InMemorySecretStore())
        store.updateSettings { $0 = settings }
        let models = await makeModels(http, engines: engines, settings: SettingsBox(settings), directory: directory.appending(path: "models"))
        meetings = MeetingStore(directory: directory, now: { t0 })
        meetingId = meetings.create().id
        controller = NotetakerController(store: store, models: models, meetings: meetings, speakers: nil, now: { t0 })
        try controller.start(meetingId)
    }

    func chunk(_ startMs: Double, _ durationMs: Double) -> MeetingChunk {
        MeetingChunk(
            session: 1, source: .system, startMs: startMs, endMs: startMs + durationMs, wallClockMs: t0 + startMs,
            wav: silentWav(durationMs: durationMs)
        )
    }

    var transcript: [TranscriptEntry] { meetings.transcript(meetingId) }
}

private let chatEndpoint = ModelSelection.endpoint(EndpointConfig(baseUrl: "https://api.openai.com/v1", model: "gpt-x", apiKey: "k"))

@MainActor
@Suite("Notetaker speaker attribution")
struct NotetakerAttributionTests {
    @Test func `credits Built-in speech-to-text segments to whoever the meeting app showed talking through them`() async throws {
        let engines = FakeEngines()
        engines.update {
            $0.transcription = EngineTranscription(
                text: " Morning, everyone. Hi Alice.",
                segments: [.init(start: 0, end: 1.8, text: " Morning, everyone."), .init(start: 2.2, end: 4, text: " Hi Alice.")]
            )
        }
        var settings = Settings()
        settings.chat = chatEndpoint
        settings.language = "en"
        let harness = try await Harness(settings, engines: engines, http: FakeHub { _, _ in .json(#"{"choices":[{"message":{"content":"Sync"}}]}"#) })

        harness.controller.handleSpeakers(SpeakersReport(platform: .meet, speaking: ["Alice Smith"], timestamp: t0))
        harness.controller.handleSpeakers(SpeakersReport(platform: .meet, speaking: ["Bob Jones"], timestamp: t0 + 2000))
        harness.controller.handleChunk(harness.chunk(0, 4000))

        await eventually { harness.transcript.count == 2 }
        #expect(harness.transcript.map { [$0.text, "\($0.startMs)", "\($0.endMs)", $0.speaker ?? "-"] } == [
            ["Morning, everyone.", "0.0", "1800.0", "app:Alice Smith"],
            ["Hi Alice.", "2200.0", "4000.0", "app:Bob Jones"],
        ])
    }

    @Test func `labels voices and sends them back as references with the diarizing Endpoint`() async throws {
        let replies = [
            #"{"segments":[{"start":0,"end":3,"text":"Shall we start?","speaker":"A"},{"start":3,"end":6,"text":"Yes, let us.","speaker":"B"}]}"#,
            #"{"segments":[{"start":0,"end":2,"text":"First item.","speaker":"speaker_2"}]}"#,
        ]
        let transcriptions = LockedCounter()
        let http = FakeHub { _, request in
            guard request.url.hasSuffix("/audio/transcriptions") else { return .json(#"{"choices":[{"message":{"content":"Sync"}}]}"#) }
            return .json(replies[min(transcriptions.next(), replies.count - 1)])
        }
        var settings = Settings()
        settings.speechToText = .endpoint(EndpointConfig(baseUrl: "https://api.openai.com/v1", model: "gpt-4o-transcribe-diarize", apiKey: "k"))
        settings.chat = chatEndpoint
        settings.language = "en"
        let harness = try await Harness(settings, http: http)

        harness.controller.handleChunk(harness.chunk(0, 6000))
        harness.controller.handleChunk(harness.chunk(6000, 2000))

        await eventually { harness.transcript.count == 3 }
        #expect(harness.transcript.map(\.speaker) == ["voice:1", "voice:2", "voice:2"])
        let forms = http.requests.filter { $0.url.hasSuffix("/audio/transcriptions") }
        #expect(forms[1].form("known_speaker_names[]") == ["speaker_1", "speaker_2"])
        #expect(forms[1].form("known_speaker_references[]").count == 2)
    }
}
