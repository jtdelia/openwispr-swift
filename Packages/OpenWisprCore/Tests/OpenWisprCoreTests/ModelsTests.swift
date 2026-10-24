import Foundation
import Synchronization
import Testing
@testable import OpenWisprCore

private let wav = Data(count: 44 + 16_000)

private func endpointSettings() -> Settings {
    var settings = Settings()
    settings.speechToText = .endpoint(EndpointConfig(baseUrl: "https://stt.example/v1/", model: "whisper-1", apiKey: "stt-key"))
    settings.chat = .endpoint(EndpointConfig(baseUrl: "https://chat.example/v1", model: "gpt-x", apiKey: "chat-key"))
    settings.language = "de"
    return settings
}

@MainActor
private func settings(_ change: (inout Settings) -> Void) -> SettingsBox {
    var settings = endpointSettings()
    change(&settings)
    return SettingsBox(settings)
}

/// A server answering every request with `reply`.
private func server(_ reply: @escaping @Sendable (String) throws -> FakeResponse = { _ in .json(#"{"text":"hello"}"#) }) -> FakeHub {
    FakeHub { _, request in try reply(request.url) }
}

private func chatReply(_ content: String) -> FakeResponse { .json(#"{"choices":[{"message":{"content":"\#(content)"}}]}"#) }

private func engines(_ change: (inout FakeEngines.Script) -> Void = { _ in }) -> FakeEngines {
    var script = FakeEngines.Script()
    change(&script)
    return FakeEngines(script)
}

/// Leaves a Recommended model's folder in `directory` the way a download does.
private func downloadedModel(_ directory: URL, _ id: String, installed: Bool = true) throws {
    let entry = try #require(recommendedModels.first { $0.id == id })
    let folder = directory.appending(path: id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    writeJsonAtomic(folder.appending(path: "manifest.json"), ModelManifest(entry: entry, userAdded: false, installed: installed, files: []))
}

private let dictation = CleanupInput(transcript: "um so lets meet on tuesday", style: .casual, category: .other, appName: "", beforeText: "", dictionary: [], userName: "")

@MainActor
@Suite("Models routing")
struct ModelsRoutingTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    @Test func `sends transcription to the speech-to-text Endpoint with its model, key and language`() async throws {
        let http = server()
        let models = await makeModels(http, settings: SettingsBox(endpointSettings()), directory: directory)
        #expect(try await models.transcribe(wav, prompt: "Jane") == "hello")
        let sent = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(sent.url == "https://stt.example/v1/audio/transcriptions")
        #expect(sent.authorization == "Bearer stt-key")
        #expect(sent.form("model") == ["whisper-1"])
        #expect(sent.form("language") == ["de"])
        #expect(sent.form("prompt") == ["Jane"])
    }

    @Test func `sends chat completions to the chat Endpoint`() async throws {
        let http = server { _ in chatReply("Tidy text.") }
        let models = await makeModels(http, settings: SettingsBox(endpointSettings()), directory: directory)
        #expect(try await models.complete([.user("tidy text")]) == "Tidy text.")
        let sent = try #require(http.requests.first)
        #expect(sent.url == "https://chat.example/v1/chat/completions")
        #expect(sent.authorization == "Bearer chat-key")
        #expect(sent.json?["model"] as? String == "gpt-x")
        #expect(sent.json?["messages"] as? [[String: String]] == [["role": "user", "content": "tidy text"]])
    }

    @Test func `lets a chat Endpoint without a key use the speech-to-text key for the same server`() async throws {
        let http = server { _ in chatReply("ok") }
        let box = settings {
            $0.speechToText = .endpoint(EndpointConfig(baseUrl: "https://api.openai.com/v1", model: "whisper-1", apiKey: "stt-key"))
            $0.chat = .endpoint(EndpointConfig(baseUrl: "https://api.openai.com/v1", model: "gpt-x", apiKey: ""))
        }
        let models = await makeModels(http, settings: box, directory: directory)
        _ = try await models.complete([.user("hi")])
        #expect(http.requests.first?.authorization == "Bearer stt-key")
    }
}

@MainActor
@Suite("Models with Built-in speech-to-text")
struct BuiltInSpeechTests {
    let directory: URL
    let apple = settings {
        $0.speechToText = .apple
        $0.language = "en"
    }

    init() throws { directory = try temporaryDirectory() }

    @Test func `sends transcription to the Apple model, with the audio in memory`() async throws {
        let http = server()
        let fake = engines { $0.transcription = EngineTranscription(text: " Hello there. ") }
        let models = await makeModels(http, engines: fake, settings: apple, directory: directory)
        #expect(models.availability(.speechToText) == .available)
        #expect(try await models.transcribe(wav, prompt: "Jane") == "Hello there.")
        #expect(http.requests.isEmpty)
        #expect(fake.calls == [.transcribe(model: "apple", language: "en", prompt: "Jane", segments: false)])
    }

    @Test func `returns timed segments clamped to the chunk for meetings`() async throws {
        let fake = engines {
            $0.transcription = EngineTranscription(text: "Hi there", segments: [.init(start: 0.5, end: 2, text: " Hi"), .init(start: 4, end: 9, text: " there")])
        }
        let models = await makeModels(engines: fake, settings: apple, directory: directory)
        #expect(try await models.transcribeSegments(wav, durationMs: 5000, prompt: "") == [
            TranscriptSegment(startMs: 500, endMs: 2000, text: "Hi"),
            TranscriptSegment(startMs: 4000, endMs: 5000, text: "there"),
        ])
        #expect(fake.calls == [.transcribe(model: "apple", language: "en", prompt: "", segments: true)])
    }

    @Test func `treats a Built-in answer without segments as one segment covering the chunk, and no text as none`() async throws {
        let untimed = await makeModels(engines: engines { $0.transcription = EngineTranscription(text: " Hi there ") }, settings: apple, directory: directory)
        #expect(try await untimed.transcribeSegments(wav, durationMs: 5000, prompt: "") == [TranscriptSegment(startMs: 0, endMs: 5000, text: "Hi there")])
        let silent = await makeModels(engines: engines { $0.transcription = EngineTranscription(text: "", segments: []) }, settings: apple, directory: directory)
        #expect(try await silent.transcribeSegments(wav, durationMs: 5000, prompt: "").isEmpty)
    }

    @Test func `loads the model for the language when a dictation starts`() async throws {
        let fake = engines()
        let models = await makeModels(engines: fake, settings: apple, directory: directory)
        models.warmUp()
        await eventually { fake.calls == [.load([ModelRef(role: .speechToText, id: "apple", language: "en")])] }
    }

    @Test func `explains when Apple does not support the dictation language`() async throws {
        let fake = engines { $0.transcribeError = .unsupportedLanguage("Apple's speech-to-text doesn't support Dutch") }
        apple.settings.language = "nl"
        let models = await makeModels(engines: fake, settings: apple, directory: directory)
        await #expect(throws: ModelError.unsupportedLanguage(
            "Apple's speech-to-text doesn't support Dutch. Download a Whisper model or choose another language in Settings"
        )) { try await models.transcribe(wav, prompt: "") }
        #expect(fake.calls == [.transcribe(model: "apple", language: "nl", prompt: "", segments: false)])
    }

    @Test func `reads the languages Apple supports from the engines`() async throws {
        let status = BuiltInStatus(appleSpeech: .init(available: true, locales: ["de-DE", "en-US"]), appleChat: .init(available: true, contextSize: 4096))
        let fake = engines { $0.status = status }
        apple.settings.language = "nl"
        let models = await makeModels(engines: fake, settings: apple, directory: directory)
        #expect(try await models.status() == status)
        #expect(fake.calls == [.status(language: "nl", speechToText: nil, chat: nil)])
    }

    @Test func `does not load anything to warm up an Endpoint`() async throws {
        let fake = engines()
        await makeModels(engines: fake, settings: SettingsBox(endpointSettings()), directory: directory).warmUp()
        try await Task.sleep(for: .milliseconds(20))
        #expect(fake.calls.isEmpty)
    }
}

@MainActor
@Suite("Models with a downloaded speech-to-text model")
struct DownloadedSpeechTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    func selected(_ id: String, language: String, engines fake: FakeEngines = FakeEngines(), http: FakeHub = server()) async throws -> Models {
        try downloadedModel(directory, id)
        let box = settings {
            $0.speechToText = .builtIn(modelId: id)
            $0.language = language
        }
        return await makeModels(http, engines: fake, settings: box, directory: directory)
    }

    @Test func `transcribes with an installed Whisper model, with the language and vocabulary hints`() async throws {
        let http = server()
        let fake = engines { $0.transcription = EngineTranscription(text: " Hallo daar. ") }
        let models = try await selected("whisper-small", language: "nl", engines: fake, http: http)
        #expect(models.availability(.speechToText) == .available)
        #expect(try await models.transcribe(wav, prompt: "Vocabulary: OpenWispr.") == "Hallo daar.")
        #expect(http.requests.isEmpty)
        #expect(fake.calls.contains(.transcribe(model: "whisper-small", language: "nl", prompt: "Vocabulary: OpenWispr.", segments: false)))
    }

    @Test func `reports a selected model that is missing or still downloading as unavailable, without using the engines`() async throws {
        try downloadedModel(directory, "whisper-small", installed: false)
        let fake = engines()
        let box = settings {
            $0.speechToText = .builtIn(modelId: "whisper-small")
            $0.language = "nl"
        }
        let models = await makeModels(engines: fake, settings: box, directory: directory)
        let reason = "Whisper small isn't downloaded. Download it or choose another speech-to-text model in Settings"
        #expect(models.availability(.speechToText) == .unavailable(reason))
        let error = await #expect(throws: (any Error).self) { try await models.transcribe(wav, prompt: "") }
        #expect(error.map(errorMessage) == reason)
        models.warmUp()
        _ = try await models.status()
        #expect(fake.calls == [.status(language: "nl", speechToText: nil, chat: nil)])
    }

    @Test func `loads the selected model when a dictation starts, and reports it as preparing while a slow first load runs`() async throws {
        let gate = Gate()
        let fake = engines { $0.loadGate = gate }
        let models = try await selected("whisper-small", language: "nl", engines: fake)
        var progress: [ModelProgress] = []
        models.onProgress = { progress.append($0) }
        func preparing() async throws -> Bool { try await status(models, "whisper-small").preparing }

        let started = ContinuousClock.now
        models.warmUp()
        models.warmUp()
        await eventually { await gate.waiting == 1 }
        #expect(fake.calls == [.load([ModelRef(role: .speechToText, id: "whisper-small", language: "nl")])])
        await eventually(timeout: .seconds(3)) { !progress.isEmpty }
        #expect(ContinuousClock.now - started >= .milliseconds(950))
        #expect(progress == [.preparingModel(modelId: "whisper-small", name: "Whisper small", preparing: true)])
        #expect(try await preparing())

        await gate.release()
        await eventually { progress.last == .preparingModel(modelId: "whisper-small", name: "Whisper small", preparing: false) }
        #expect(try await !preparing())
    }

    @Test func `does not report a quick load as preparing`() async throws {
        let models = try await selected("whisper-small", language: "nl")
        var progress: [ModelProgress] = []
        models.onProgress = { progress.append($0) }
        models.warmUp()
        try await Task.sleep(for: .milliseconds(1300))
        #expect(progress.isEmpty)
    }

    @Test func `refuses to remove the selected model, but removes others`() async throws {
        try downloadedModel(directory, "whisper-large-v3-turbo")
        let models = try await selected("whisper-small", language: "nl")
        let error = await #expect(throws: AppError.self) { _ = try await models.removeModel("whisper-small") }
        #expect(error?.message == "Whisper small is selected for speech-to-text. Choose another model in Settings before removing it")
        #expect(models.availability(.speechToText) == .available)
        #expect(try await models.removeModel("whisper-large-v3-turbo") > 0)
        #expect(try await status(models, "whisper-large-v3-turbo").state == .notDownloaded)
    }

    @Test func `does not offer to download Whisper when Whisper itself lacks the language`() async throws {
        let fake = engines { $0.transcribeError = .unsupportedLanguage("Whisper small doesn't support Klingon") }
        let models = try await selected("whisper-small", language: "tlh", engines: fake)
        await #expect(throws: ModelError.unsupportedLanguage("Whisper small doesn't support Klingon. Choose another language in Settings")) {
            try await models.transcribe(wav, prompt: "")
        }
    }

    @Test func `reports an installed model that is not for speech-to-text as unavailable`() async throws {
        let models = try await selected("qwen3-4b-instruct-2507", language: "nl")
        #expect(models.availability(.speechToText).reason?.contains("isn't a speech-to-text model") == true)
    }

    @Test func `sends dictations to the Parakeet model`() async throws {
        let fake = engines { $0.transcription = EngineTranscription(text: " Guten Morgen. ") }
        let models = try await selected("parakeet-tdt-0.6b-v3", language: "de", engines: fake)
        #expect(models.availability(.speechToText) == .available)
        #expect(try await models.transcribe(wav, prompt: "Jane") == "Guten Morgen.")
        #expect(fake.calls.contains(.transcribe(model: "parakeet-tdt-0.6b-v3", language: "de", prompt: "Jane", segments: false)))
    }

    @Test func `asks the engines which languages the selected Parakeet model supports`() async throws {
        let status = BuiltInStatus(
            appleSpeech: .init(available: true, locale: "ja-JP", locales: ["ja-JP"]), appleChat: .init(available: true, contextSize: 4096),
            speechToText: .init(model: "parakeet-tdt-0.6b-v3", name: "Parakeet TDT v3", supported: false, languages: ["de", "en"])
        )
        let fake = engines { $0.status = status }
        let models = try await selected("parakeet-tdt-0.6b-v3", language: "ja", engines: fake)
        #expect(try await models.status() == status)
        #expect(fake.calls.contains(.status(language: "ja", speechToText: "parakeet-tdt-0.6b-v3", chat: nil)))
    }

    @Test func `explains when Parakeet does not support the dictation language`() async throws {
        let fake = engines { $0.transcribeError = .unsupportedLanguage("Parakeet TDT v3 doesn't support Japanese") }
        let models = try await selected("parakeet-tdt-0.6b-v3", language: "ja", engines: fake)
        await #expect(throws: ModelError.unsupportedLanguage(
            "Parakeet TDT v3 doesn't support Japanese. Download a Whisper model or choose another language in Settings"
        )) { try await models.transcribe(wav, prompt: "") }
    }
}

@MainActor
@Suite("Models with Built-in chat")
struct BuiltInChatTests {
    let directory: URL
    let appleChat = settings { $0.chat = .apple }
    init() throws { directory = try temporaryDirectory() }

    @Test func `sends chat messages to Apple's model with an output cap`() async throws {
        let http = server()
        let fake = engines { $0.completion = " Tidy text. " }
        let models = await makeModels(http, engines: fake, settings: appleChat, directory: directory)
        let messages: [ChatMessage] = [.system("Clean up."), .user("tidy text")]
        #expect(models.availability(.chat) == .available)
        #expect(try await models.complete(messages, maxTokens: 300) == "Tidy text.")
        #expect(http.requests.isEmpty)
        #expect(fake.calls == [.complete(model: "apple", maxTokens: 300)])
        #expect(fake.lastMessages == messages)
    }

    @Test func `loads Apple's chat model along with speech-to-text when a dictation starts`() async {
        let fake = engines()
        let box = settings {
            $0.speechToText = .apple
            $0.chat = .apple
            $0.language = "en"
        }
        await makeModels(engines: fake, settings: box, directory: directory).warmUp()
        await eventually {
            fake.calls == [.load([ModelRef(role: .speechToText, id: "apple", language: "en"), ModelRef(role: .chat, id: "apple", language: "en")])]
        }
    }

    @Test func `reads the chat model's context size from the engines, and has none for an Endpoint`() async {
        let models = await makeModels(engines: engines(), settings: appleChat, directory: directory)
        #expect(await models.chatContextSize() == 4096)
        #expect(await makeModels(settings: SettingsBox(endpointSettings()), directory: directory).chatContextSize() == nil)
    }

    @Test func `explains in the status when Apple Intelligence is off`() async throws {
        let status = BuiltInStatus(
            appleSpeech: .init(available: true, locale: "en-US", locales: ["en-US"]),
            appleChat: .init(available: false, reason: "Apple Intelligence is off", fix: .turnOnAppleIntelligence)
        )
        let models = await makeModels(engines: engines { $0.status = status }, settings: appleChat, directory: directory)
        #expect(try await models.status() == status)
        #expect(await models.chatContextSize() == nil)
    }
}

@MainActor
@Suite("Models Cleanup")
struct CleanupTests {
    let directory: URL
    let appleChat = settings { $0.chat = .apple }
    init() throws { directory = try temporaryDirectory() }

    func cleanup(_ change: (inout FakeEngines.Script) -> Void, _ input: CleanupInput = dictation) async -> (CleanupResult, FakeEngines) {
        let fake = engines(change)
        return (await makeModels(engines: fake, settings: appleChat, directory: directory).cleanup(input), fake)
    }

    @Test func `keeps the transcript and says why when Apple Intelligence is off`() async {
        let (result, fake) = await cleanup { $0.completeError = .unavailable("Apple Intelligence is off") }
        #expect(result == CleanupResult(text: "um so lets meet on tuesday", notice: "Cleanup skipped: Apple Intelligence is off"))
        guard case .complete(model: "apple", _) = fake.calls.first else {
            Issue.record("\(fake.calls)")
            return
        }
    }

    @Test func `keeps the transcript quietly when the model refuses, whether as an error or as its answer`() async {
        #expect(await cleanup { $0.completeError = .refused("Guardrail violation") }.0 == CleanupResult(text: dictation.transcript, notice: nil))
        for answer in ["Unable to work with that request.", "I'm sorry, but I can't assist with that.", "I cannot help with that request."] {
            #expect(await cleanup { $0.completion = answer }.0 == CleanupResult(text: dictation.transcript, notice: nil))
        }
    }

    @Test func `keeps a dictated apology, which is not a refusal`() async {
        var input = dictation
        input.transcript = "um im sorry i cant make it tonight"
        let (result, _) = await cleanup({ $0.completion = "I'm sorry, I can't make it tonight." }, input)
        #expect(result == CleanupResult(text: "I'm sorry, I can't make it tonight.", notice: nil))
    }

    @Test func `returns the cleaned text and asks for an answer about as long as the dictation`() async throws {
        let (result, fake) = await cleanup { $0.completion = "So let's meet on Tuesday." }
        #expect(result == CleanupResult(text: "So let's meet on Tuesday.", notice: nil))
        guard case let .complete("apple", maxTokens) = try #require(fake.calls.first) else {
            Issue.record("\(fake.calls)")
            return
        }
        #expect(maxTokens >= dictation.transcript.count / 2)
        #expect(maxTokens < 1024)
    }

    @Test func `keeps the transcript when it is too long for the model`() async {
        let (result, _) = await cleanup { $0.completeError = .contextExceeded("Too long for Apple's chat model (5120 of 4096 tokens)") }
        #expect(result == CleanupResult(text: dictation.transcript, notice: "Cleanup skipped: Too long for Apple's chat model (5120 of 4096 tokens)"))
    }

    @Test func `keeps the transcript when a cloud chat Endpoint rejects the request, such as without a key`() async {
        let http = server { _ in .json(#"{"error":{"message":"Missing bearer authentication"}}"#, status: 401) }
        let box = settings { $0.chat = .endpoint(EndpointConfig(baseUrl: "https://chat.example/v1", model: "gpt-x", apiKey: "")) }
        let result = await makeModels(http, settings: box, directory: directory).cleanup(dictation)
        #expect(result == CleanupResult(text: dictation.transcript, notice: "Cleanup failed: Chat failed (401): Missing bearer authentication"))
    }

    @Test func `keeps the transcript when the model fails`() async {
        let (result, _) = await cleanup { $0.completeError = .modelFailed("The model stopped unexpectedly") }
        #expect(result == CleanupResult(text: dictation.transcript, notice: "Cleanup failed: The model stopped unexpectedly"))
    }
}

@MainActor
@Suite("Models segments for meetings")
struct EndpointSegmentsTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    func withModel(_ model: String, _ reply: String) async -> (Models, FakeHub) {
        let http = server { _ in .json(reply) }
        let box = settings { $0.speechToText = .endpoint(EndpointConfig(baseUrl: "https://stt.example/v1/", model: model, apiKey: "stt-key")) }
        return (await makeModels(http, settings: box, directory: directory), http)
    }

    @Test func `asks Whisper models for timed segments and clamps them to the chunk`() async throws {
        let (models, http) = await withModel("whisper-large-v3-turbo", #"{"segments":[{"start":0.5,"end":2,"text":" Hi "},{"start":4,"end":9,"text":"there"},{"text":" "}]}"#)
        #expect(try await models.transcribeSegments(wav, durationMs: 5000, prompt: "Jane") == [
            TranscriptSegment(startMs: 500, endMs: 2000, text: "Hi"),
            TranscriptSegment(startMs: 4000, endMs: 5000, text: "there"),
        ])
        let sent = try #require(http.requests.first)
        #expect(sent.form("response_format") == ["verbose_json"])
        #expect(sent.form("timestamp_granularities[]") == ["segment"])
        #expect(sent.form("prompt") == ["Jane"])
    }

    @Test func `sends known voices to diarizing models and keeps their speaker labels`() async throws {
        let (models, http) = await withModel("gpt-4o-transcribe-diarize", #"{"segments":[{"start":0,"end":1,"text":"Hello","speaker":"voice-1"}]}"#)
        let known = KnownSpeakers(names: ["voice-1"], references: ["data:audio/wav;base64,AAAA"])
        #expect(try await models.transcribeSegments(wav, durationMs: 3000, prompt: "Jane", known: known) == [
            TranscriptSegment(startMs: 0, endMs: 1000, text: "Hello", speaker: "voice-1"),
        ])
        let sent = try #require(http.requests.first)
        #expect(sent.form("response_format") == ["diarized_json"])
        #expect(sent.form("known_speaker_names[]") == ["voice-1"])
        #expect(sent.form("known_speaker_references[]") == ["data:audio/wav;base64,AAAA"])
        #expect(sent.form("prompt").isEmpty)
    }

    @Test func `treats untimed text as one segment covering the chunk, and no text as none`() async throws {
        let (plain, http) = await withModel("gpt-4o-mini-transcribe", #"{"text":" Hello there "}"#)
        #expect(try await plain.transcribeSegments(wav, durationMs: 5000, prompt: "") == [TranscriptSegment(startMs: 0, endMs: 5000, text: "Hello there")])
        #expect(http.requests.first?.form("response_format") == ["json"])
        let (silent, _) = await withModel("gpt-4o-mini-transcribe", #"{"text":""}"#)
        #expect(try await silent.transcribeSegments(wav, durationMs: 5000, prompt: "").isEmpty)
    }

    @Test func `falls back to the whole text when a timed reply has no usable segments, and to none when it has no text`() async throws {
        let whole = [TranscriptSegment(startMs: 0, endMs: 5000, text: "Hello there")]
        let (untimed, _) = await withModel("whisper-large-v3-turbo", #"{"text":"Hello there","segments":[{"start":0,"end":1,"text":" "}]}"#)
        #expect(try await untimed.transcribeSegments(wav, durationMs: 5000, prompt: "") == whole)
        let (missing, _) = await withModel("whisper-large-v3-turbo", #"{"text":"Hello there"}"#)
        #expect(try await missing.transcribeSegments(wav, durationMs: 5000, prompt: "") == whole)
        let (silent, _) = await withModel("whisper-large-v3-turbo", #"{"text":"","segments":[]}"#)
        #expect(try await silent.transcribeSegments(wav, durationMs: 5000, prompt: "").isEmpty)
    }
}

@MainActor
@Suite("Models Endpoint test")
struct EndpointTestTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    @Test func `reports success when each Endpoint answers`() async {
        let http = server { url in url.hasSuffix("/chat/completions") ? chatReply("OK") : .json(#"{"text":""}"#) }
        let models = await makeModels(http, settings: SettingsBox(endpointSettings()), directory: directory)
        #expect(await models.testEndpoint(.speechToText) == .ok)
        #expect(await models.testEndpoint(.chat) == .ok)
        #expect(http.requests.map(\.url) == ["https://stt.example/v1/audio/transcriptions", "https://chat.example/v1/chat/completions"])
        #expect(http.requests.first?.authorization == "Bearer stt-key")
        #expect(http.requests.last?.json?["model"] as? String == "gpt-x")
    }

    @Test func `reports the server's error`() async {
        let http = server { _ in .json(#"{"error":{"message":"Incorrect API key provided"}}"#, status: 401) }
        let models = await makeModels(http, settings: SettingsBox(endpointSettings()), directory: directory)
        #expect(await models.testEndpoint(.chat) == .failed("Chat failed (401): Incorrect API key provided"))
        #expect(await models.testEndpoint(.speechToText) == .failed("Transcription failed (401): Incorrect API key provided"))
    }

    @Test func `reports an unreachable server`() async {
        let http = server { _ in throw Dropped(message: "fetch failed") }
        let models = await makeModels(http, settings: SettingsBox(endpointSettings()), directory: directory)
        #expect(await models.testEndpoint(.chat) == .failed("fetch failed"))
    }
}

private func loadSettings(_ json: String) throws -> Settings {
    try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
}

@Suite("Settings migration")
struct SettingsMigrationTests {
    let groqFile = #"""
    {"transcription":{"baseUrl":"https://api.groq.com/openai/v1","model":"whisper-large-v3-turbo","apiKey":"enc:groq","language":"fr"},
     "cleanup":{"enabled":false,"baseUrl":"https://api.groq.com/openai/v1","model":"llama-3.3-70b-versatile","apiKey":""},
     "sounds":false,"userName":"Jane"}
    """#
    let openAiDefault = #"""
    "transcription":{"baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-transcribe","apiKey":"","language":""}
    """#

    @Test func `turns the old per-role settings into Endpoint selections with the same values`() throws {
        let settings = try loadSettings(groqFile)
        #expect(settings.speechToText == .endpoint(EndpointConfig(baseUrl: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo", apiKey: "enc:groq")))
        #expect(settings.chat == .endpoint(EndpointConfig(baseUrl: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile", apiKey: "enc:groq")))
        #expect(settings.language == "fr")
        #expect(settings.cleanup == Settings.Cleanup(enabled: false))
        #expect(!settings.sounds)
        #expect(settings.userName == "Jane")
    }

    @Test func `gives a fresh install Apple's models for both roles, so it works with no key and no download`() throws {
        let fresh = try loadSettings("{}")
        #expect(fresh.speechToText == .apple && fresh.chat == .apple)
        #expect(fresh.cleanup.enabled)
    }

    @Test func `moves an untouched OpenAI default to Apple, keeping custom base URLs and stored keys on Endpoints`() throws {
        let cleanup = #""cleanup":{"enabled":true,"baseUrl":"https://api.openai.com/v1","model":"gpt-4.1-mini","apiKey":""}"#
        let untouched = try loadSettings("{\(openAiDefault),\(cleanup)}")
        #expect(untouched.speechToText == .apple && untouched.chat == .apple)

        let withChatKey = try loadSettings("{\(openAiDefault),\(cleanup.replacingOccurrences(of: #""apiKey":"""#, with: #""apiKey":"enc:chat""#))}")
        #expect(withChatKey.speechToText == .apple)
        #expect(withChatKey.chat == .endpoint(EndpointConfig(baseUrl: "https://api.openai.com/v1", model: "gpt-4.1-mini", apiKey: "enc:chat")))

        let local = try loadSettings(#"{"transcription":{"baseUrl":"http://localhost:8000/v1","model":"distil-whisper","apiKey":""},\#(cleanup)}"#)
        #expect(local.speechToText == .endpoint(EndpointConfig(baseUrl: "http://localhost:8000/v1", model: "distil-whisper", apiKey: "")))
    }

    @Test func `keeps chat on the Endpoint whose key it shared with transcription, with its own copy of the key`() throws {
        let settings = try loadSettings(#"""
        {"transcription":{"baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-transcribe","apiKey":"enc:openai"},
         "cleanup":{"enabled":true,"baseUrl":"https://api.openai.com/v1","model":"gpt-4.1-mini","apiKey":""}}
        """#)
        #expect(settings.speechToText.endpoint?.apiKey == "enc:openai")
        #expect(settings.chat == .endpoint(EndpointConfig(baseUrl: "https://api.openai.com/v1", model: "gpt-4.1-mini", apiKey: "enc:openai")))
    }

    @Test func `drops the API key when the base URL moves to another server, so it is never sent there`() {
        let openAi = ModelSelection.apple.applying(.endpoint(baseUrl: "https://api.openai.com/v1", model: "gpt-4o-mini-transcribe", apiKey: "enc:openai"))
        #expect(openAi.applying(.endpoint(baseUrl: "https://api.openai.com/v2")).endpoint?.apiKey == "enc:openai")
        let groq = openAi.applying(.endpoint(baseUrl: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo"))
        #expect(groq.endpoint?.baseUrl == "https://api.groq.com/openai/v1" && groq.endpoint?.apiKey == "")
        #expect(openAi.applying(.endpoint(baseUrl: "https://api.groq.com/openai/v1", apiKey: "enc:groq")).endpoint?.apiKey == "enc:groq")
    }

    @Test func `leaves already-migrated Endpoint selections alone`() throws {
        let settings = try loadSettings(groqFile)
        let roundTripped = try JSONDecoder().decode(Settings.self, from: try JSONEncoder().encode(settings))
        #expect(roundTripped == settings)
    }
}

@MainActor
@Suite("Models availability")
struct AvailabilityTests {
    let directory: URL
    let keyless = EndpointConfig(baseUrl: "http://localhost:11434/v1", model: "llama3.2", apiKey: "")
    init() throws { directory = try temporaryDirectory() }

    @Test func `makes a keyless chat Endpoint available, so Cleanup runs against local servers`() async throws {
        let http = server { _ in chatReply("ok") }
        let keyless = keyless
        let models = await makeModels(http, settings: settings { $0.chat = .endpoint(keyless) }, directory: directory)
        #expect(models.availability(.chat) == .available)
        _ = try await models.complete([.user("hi")])
        #expect(http.requests.first?.url == "http://localhost:11434/v1/chat/completions")
        #expect(http.requests.first?.authorization == nil)
    }

    @Test func `needs a chat model name`() async {
        var config = keyless
        config.model = " "
        let models = await makeModels(settings: settings { $0.chat = .endpoint(config) }, directory: directory)
        #expect(models.availability(.chat) == .unavailable("Set up a chat model in Settings"))
    }

    @Test func `asks for a key before transcribing with a cloud Endpoint, but not a local one`() async {
        let cloud = await makeModels(settings: settings { $0.speechToText = .endpoint(EndpointConfig(baseUrl: "https://stt.example/v1/", model: "whisper-1", apiKey: "")) }, directory: directory)
        #expect(cloud.availability(.speechToText) == .unavailable("Add a speech-to-text API key in Settings"))
        let keyless = keyless
        let local = await makeModels(settings: settings { $0.speechToText = .endpoint(keyless) }, directory: directory)
        #expect(local.availability(.speechToText) == .available)
    }
}

@MainActor
@Suite("Models with a downloaded chat model")
struct DownloadedChatTests {
    let directory: URL
    let qwen = "qwen3-4b-instruct-2507"
    init() throws { directory = try temporaryDirectory() }

    func selected(_ id: String? = nil, engines fake: FakeEngines = FakeEngines(), installed: Bool = true) async throws -> Models {
        let id = id ?? qwen
        try downloadedModel(directory, id, installed: installed)
        return await makeModels(engines: fake, settings: settings { $0.chat = .builtIn(modelId: id) }, directory: directory)
    }

    @Test func `sends chat messages to an installed MLX model`() async throws {
        let fake = engines { $0.completion = " Tidy text. " }
        let models = try await selected(engines: fake)
        #expect(models.availability(.chat) == .available)
        #expect(try await models.complete([.user("tidy text")], maxTokens: 300) == "Tidy text.")
        #expect(fake.calls == [.complete(model: qwen, maxTokens: 300)])
    }

    @Test func `reports a selected chat model that is missing or still downloading as unavailable, without using the engines`() async throws {
        let fake = engines()
        let models = try await selected(engines: fake, installed: false)
        let reason = "Qwen3 4B Instruct isn't downloaded. Download it or choose another chat model in Settings"
        #expect(models.availability(.chat) == .unavailable(reason))
        await #expect(throws: (any Error).self) { try await models.complete([.user("hi")]) }
        #expect(await models.cleanup(dictation) == CleanupResult(text: dictation.transcript, notice: "Cleanup skipped: \(reason)"))
        #expect(fake.calls.isEmpty)
    }

    @Test func `reads the selected chat model's context size from the engines`() async throws {
        let status = BuiltInStatus(
            appleSpeech: .init(available: true, locale: "de-DE", locales: ["de-DE"]), appleChat: .init(available: true, contextSize: 4096),
            chat: .init(model: qwen, name: "Qwen3 4B Instruct", contextSize: 32_768)
        )
        let fake = engines { $0.status = status }
        let models = try await selected(engines: fake)
        #expect(await models.chatContextSize() == 32_768)
        #expect(fake.calls == [.status(language: "de", speechToText: nil, chat: qwen)])
    }

    @Test func `reports an installed model that is not for chat as unavailable`() async throws {
        let models = try await selected("whisper-small")
        #expect(models.availability(.chat) == .unavailable("Whisper small isn't a chat model"))
    }
}
