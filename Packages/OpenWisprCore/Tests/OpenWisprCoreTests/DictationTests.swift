import Foundation
import Testing
@testable import OpenWisprCore

@MainActor
private final class FakeSystem: DictationSystem {
    var app = AppInfo(appName: "Notes", bundleId: "com.apple.Notes", windowTitle: "")
    var textBox: TextBoxInfo? = TextBoxInfo(accessibilityIsFunctioning: true, couldNotGetTextBoxInfo: false, isEditable: true, beforeText: "")
    var pasteSucceeds = true
    private(set) var pasted: [String] = []
    private(set) var copied: [String] = []
    private(set) var sounds: [Sound] = []
    private(set) var swallowed: [[Int]] = []
    private(set) var settingsShown = 0

    func appInfo() async -> AppInfo { app }
    func textBoxInfo() async -> TextBoxInfo? { textBox }

    func paste(_ text: String, restoreClipboard: Bool) async -> Bool {
        pasted.append(text)
        return pasteSucceeds
    }

    func copy(_ text: String) { copied.append(text) }
    func setSwallowedCombos(_ combos: [[Int]]) { swallowed = combos }
    func play(_ sound: Sound) { sounds.append(sound) }
    func showSettings() { settingsShown += 1 }
}

@MainActor
private final class FakeRecorder: DictationRecorder {
    private(set) var events: [String] = []
    var level: Float = 0

    func start(deviceId: String) { events.append("start") }
    func stop() { events.append("stop") }
    func cancel() { events.append("cancel") }
}

@MainActor
private final class Clock {
    var ms = 1_000_000.0
}

@MainActor
private struct Harness {
    let controller: DictationController
    let store: DataStore
    let system = FakeSystem()
    let recorder = FakeRecorder()
    let engines: FakeEngines
    let clock = Clock()

    init(cleanup: Bool = false, change: (inout Settings) -> Void = { _ in }, engines: FakeEngines = FakeEngines()) async throws {
        let directory = try temporaryDirectory()
        store = DataStore(directory: directory, secrets: InMemorySecretStore())
        store.updateSettings {
            $0.cleanup.enabled = cleanup
            change(&$0)
        }
        self.engines = engines
        let store = store
        let models = await makeModels(engines: engines, settings: SettingsBox(store.settings), directory: directory.appending(path: "models"))
        let clock = clock
        controller = DictationController(
            store: store, models: models, system: system, engine: ShortcutEngine(shortcuts: store.settings.shortcuts), now: { clock.ms }
        )
        controller.recorder = recorder
    }

    /// Holds push-to-talk for `ms`, then hands over `wav`.
    func dictate(holdMs: Double = 1000, wav: Data = silentWav(durationMs: 1000)) async {
        controller.handleGesture(.pttStart)
        controller.recorderStarted()
        clock.ms += holdMs
        controller.handleGesture(.pttEnd)
        await controller.handleAudio(wav)
    }
}

private func speech(_ text: String) -> FakeEngines {
    let engines = FakeEngines()
    engines.update { $0.transcription = EngineTranscription(text: text) }
    return engines
}

@MainActor
@Suite("Dictation")
struct DictationTests {
    @Test func `pastes the transcript into the focused text field and records it in History`() async throws {
        let harness = try await Harness(engines: speech("hello world"))

        await harness.dictate()

        #expect(harness.recorder.events == ["start", "stop"])
        #expect(harness.system.pasted == ["hello world"])
        #expect(harness.system.sounds == [.start, .stop])
        let entry = try #require(harness.store.history.first)
        #expect(entry.status == .pasted && entry.formattedText == "hello world" && entry.mode == .ptt)
        #expect(entry.appName == "Notes" && entry.durationMs == 1000 && entry.numWords == 2)
        #expect(harness.controller.flowBarState == .resting)
    }

    @Test func `treats a push-to-talk tap shorter than half a second as accidental`() async throws {
        let harness = try await Harness()
        harness.controller.handleGesture(.pttStart)
        harness.clock.ms += 300
        harness.controller.handleGesture(.pttEnd)

        #expect(harness.recorder.events == ["start", "cancel"])
        #expect(!harness.controller.isActive)
        #expect(harness.engines.calls.allSatisfy { if case .transcribe = $0 { false } else { true } })
    }

    @Test func `claims Esc only while dictating`() async throws {
        let harness = try await Harness()
        harness.controller.syncShortcuts()
        #expect(!harness.system.swallowed.contains([Key.esc]))
        harness.controller.handleGesture(.pttStart)
        #expect(harness.system.swallowed.contains([Key.esc]))
        harness.controller.handleGesture(.dismiss)
        #expect(!harness.system.swallowed.contains([Key.esc]))
    }

    @Test func `copies instead when no editable text field is focused`() async throws {
        let harness = try await Harness(engines: speech("hello world"))
        harness.system.textBox = TextBoxInfo(accessibilityIsFunctioning: true, couldNotGetTextBoxInfo: false, isEditable: false, beforeText: "")

        await harness.dictate()

        #expect(harness.system.pasted.isEmpty)
        #expect(harness.system.copied == ["hello world"])
        #expect(harness.store.history.first?.status == .copied)
        #expect(harness.controller.flowBarState == .notice("No text field focused. Copied to clipboard", .info))
    }

    @Test func `tells the user to grant Accessibility when it can't paste`() async throws {
        let harness = try await Harness(engines: speech("hello"))
        harness.system.textBox = TextBoxInfo(accessibilityIsFunctioning: false, couldNotGetTextBoxInfo: true, isEditable: false, beforeText: "")
        await harness.dictate()
        #expect(harness.controller.flowBarState == .notice("Copied. Grant Accessibility to auto-paste", .info))
    }

    @Test func `ignores a recording too short to hold speech`() async throws {
        let harness = try await Harness()
        await harness.dictate(wav: silentWav(durationMs: 100))
        #expect(harness.store.history.isEmpty)
        #expect(harness.controller.flowBarState == .notice("No audio captured", .info))
    }

    @Test func `records an empty transcript without pasting`() async throws {
        let harness = try await Harness(engines: speech(""))
        await harness.dictate()
        #expect(harness.system.pasted.isEmpty)
        #expect(harness.store.history.first?.status == .empty)
        #expect(harness.controller.flowBarState == .notice("No speech detected", .info))
    }

    @Test func `applies Dictionary replacements and Snippets`() async throws {
        let harness = try await Harness(engines: speech("ping open whisper"))
        harness.store.setDictionary([DictionaryEntry(word: "OpenWispr", replaces: "open whisper")])
        harness.store.setSnippets([Snippet(trigger: "ping", expansion: "Pong!")])
        await harness.dictate()
        #expect(harness.system.pasted == ["Pong! OpenWispr"])
    }

    @Test func `expands a Snippet that is the whole dictation without Cleanup`() async throws {
        let engines = speech("my address.")
        let harness = try await Harness(cleanup: true, engines: engines)
        harness.store.setSnippets([Snippet(trigger: "my address", expansion: "1 Infinite Loop")])
        await harness.dictate()
        #expect(harness.system.pasted == ["1 Infinite Loop"])
        #expect(!engines.calls.contains { if case .complete = $0 { true } else { false } })
    }

    @Test func `cleans the transcript up with the chat model when Cleanup is on`() async throws {
        let engines = speech("um so lets meet on tuesday")
        engines.update { $0.completion = "So let's meet on Tuesday." }
        let harness = try await Harness(cleanup: true, engines: engines)
        await harness.dictate()
        #expect(harness.system.pasted == ["So let's meet on Tuesday."])
        #expect(harness.store.history.first?.asrText == "um so lets meet on tuesday")
    }

    @Test func `adds a space after the text before the cursor`() async throws {
        let harness = try await Harness(engines: speech("world"))
        harness.system.textBox = TextBoxInfo(accessibilityIsFunctioning: true, couldNotGetTextBoxInfo: false, isEditable: true, beforeText: "Hello")
        await harness.dictate()
        #expect(harness.system.pasted == [" world"])
    }

    @Test func `shows the error and keeps it in History when transcription fails`() async throws {
        let engines = FakeEngines()
        engines.update { $0.transcribeError = .modelFailed("The model stopped") }
        let harness = try await Harness(engines: engines)
        await harness.dictate()
        #expect(harness.system.sounds.last == .error)
        #expect(harness.store.history.first?.status == .error)
        #expect(harness.store.history.first?.error == "The model stopped")
        #expect(harness.controller.flowBarState == .notice("The model stopped", .error))
    }

    @Test func `drops the audio of a dictation cancelled while it was transcribing`() async throws {
        let harness = try await Harness(engines: speech("hello"))
        harness.controller.handleGesture(.pttStart)
        harness.clock.ms += 1000
        harness.controller.handleGesture(.pttEnd)
        harness.controller.cancel()
        await harness.controller.handleAudio(silentWav(durationMs: 1000))
        #expect(harness.system.pasted.isEmpty)
        #expect(harness.store.history.isEmpty)
    }

    @Test func `opens Settings instead of recording when no speech-to-text model is set up`() async throws {
        let harness = try await Harness { $0.speechToText = .endpoint(EndpointConfig(baseUrl: "https://api.openai.com/v1", model: "whisper-1", apiKey: "")) }
        harness.controller.handleGesture(.pttStart)
        #expect(harness.recorder.events.isEmpty)
        #expect(harness.system.settingsShown == 1)
        #expect(harness.controller.flowBarState == .notice("Add a speech-to-text API key in Settings", .error))
    }

    @Test func `locks hands-free so releasing the keys keeps recording`() async throws {
        let harness = try await Harness(engines: speech("hands free"))
        harness.controller.handleGesture(.pttStart)
        harness.controller.recorderStarted()
        harness.controller.handleGesture(.handsFreeLock)
        #expect(harness.controller.flowBarState == .listening(.handsFree))
        harness.controller.handleGesture(.pttEnd)
        #expect(harness.recorder.events == ["start"])
        harness.clock.ms += 5000
        harness.controller.handleGesture(.handsFreeStop)
        await harness.controller.handleAudio(silentWav(durationMs: 1000))
        #expect(harness.system.pasted == ["hands free"])
        #expect(harness.store.history.first?.mode == .handsFree)
        #expect(harness.system.sounds == [.start, .lock, .stop])
    }

    @Test func `copies the last transcript`() async throws {
        let harness = try await Harness(engines: speech("hello world"))
        await harness.dictate()
        harness.controller.handleGesture(.copyLast)
        #expect(harness.system.copied == ["hello world"])
        #expect(harness.controller.flowBarState == .notice("Copied last transcript", .info))
    }

    @Test func `hides the resting Flow bar when the setting is off`() async throws {
        let harness = try await Harness { $0.showFlowBar = false }
        harness.controller.refreshFlowBar()
        #expect(harness.controller.flowBarState == .hidden)
        harness.controller.handleGesture(.pttStart)
        #expect(harness.controller.flowBarState == .initializing(.ptt))
    }

    @Test func `reports a microphone failure`() async throws {
        let harness = try await Harness()
        harness.controller.handleGesture(.pttStart)
        harness.controller.recorderFailed("No input device")
        #expect(!harness.controller.isActive)
        #expect(harness.controller.flowBarState == .notice("Microphone error: No input device", .error))
    }
}

@MainActor
@Suite("Data store")
struct DataStoreTests {
    @Test func `keeps API keys in the secret store and out of the settings file`() throws {
        let directory = try temporaryDirectory()
        let secrets = InMemorySecretStore()
        let store = DataStore(directory: directory, secrets: secrets)
        store.updateSelection(.speechToText, .endpoint(baseUrl: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo", apiKey: "gsk-secret"))

        let file = try String(contentsOf: directory.appending(path: "openwispr.json"), encoding: .utf8)
        #expect(!file.contains("gsk-secret"))
        #expect(secrets.secret("speechToText") == "gsk-secret")
        let reopened = DataStore(directory: directory, secrets: secrets)
        #expect(reopened.settings.speechToText.endpoint?.apiKey == "gsk-secret")
    }

    @Test func `moves plaintext keys from an imported settings file into the secret store, dropping ones encrypted by the Electron app`() throws {
        let directory = try temporaryDirectory()
        let legacy = #"""
        {"settings":{"transcription":{"baseUrl":"https://api.groq.com/openai/v1","model":"whisper-large-v3-turbo","apiKey":"gsk-plain"},
         "cleanup":{"enabled":true,"baseUrl":"https://api.openai.com/v1","model":"gpt-4.1-mini","apiKey":"enc:djEw"}},
         "dictionary":[{"id":"1","word":"OpenWispr"},{"broken":true}],"snippets":[]}
        """#
        try Data(legacy.utf8).write(to: directory.appending(path: "openwispr.json"))
        let secrets = InMemorySecretStore()

        let store = DataStore(directory: directory, secrets: secrets)

        #expect(store.settings.speechToText.endpoint?.apiKey == "gsk-plain")
        #expect(store.settings.chat.endpoint?.apiKey == "")
        #expect(secrets.secret("speechToText") == "gsk-plain")
        #expect(store.dictionary.map(\.word) == ["OpenWispr"])
        let file = try String(contentsOf: directory.appending(path: "openwispr.json"), encoding: .utf8)
        #expect(!file.contains("gsk-plain") && !file.contains("enc:"))
    }

    @Test func `keeps the newest 2000 dictations and totals words per minute`() throws {
        let store = DataStore(directory: try temporaryDirectory(), secrets: InMemorySecretStore())
        for i in 0..<2001 {
            store.addHistory(HistoryEntry(
                timestamp: Double(i), mode: .ptt, status: .pasted, asrText: "a b", formattedText: "a b \(i)",
                appName: "", bundleId: "", durationMs: 1000, numWords: 3, error: nil
            ))
        }
        #expect(store.history.count == DataStore.historyLimit)
        #expect(store.history.first?.formattedText == "a b 2000")
        #expect(store.lastText() == "a b 2000")
        #expect(store.stats == Stats(totalWords: 6000, totalDictations: 2000, averageWpm: 180))
    }

    @Test func `writes History to disk on flush`() throws {
        let directory = try temporaryDirectory()
        let store = DataStore(directory: directory, secrets: InMemorySecretStore())
        store.addHistory(HistoryEntry(
            timestamp: 1, mode: .handsFree, status: .copied, asrText: "hi", formattedText: "Hi.", appName: "Notes", bundleId: "", durationMs: 500,
            numWords: 1, error: nil
        ))
        store.flush()
        let reopened = DataStore(directory: directory, secrets: InMemorySecretStore())
        #expect(reopened.history.map(\.formattedText) == ["Hi."])
    }
}
