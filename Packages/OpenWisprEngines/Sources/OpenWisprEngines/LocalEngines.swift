import Foundation
import OpenWisprCore
import Synchronization

/// A speech-to-text engine for one model, fed 16 kHz mono samples in -1...1.
protocol SpeechToTextEngine: Sendable {
    /// ISO language codes it transcribes, or nil when it isn't limited to a known set.
    var languages: [String]? { get }
    /// Gets the model ready for `language`, downloading what it needs.
    func load(language: String) async throws
    func transcribe(_ samples: [Float], language: String, prompt: String) async throws -> [EngineTranscription.Segment]
    func unload() async
}

protocol ChatEngine: Sendable {
    /// Gets the model ready so the next request answers quickly.
    func load() async throws
    func complete(_ messages: [ChatMessage], maxTokens: Int) async throws -> String
    func unload() async
}

extension SpeechToTextEngine {
    var languages: [String]? { nil }

    /// An empty setting means the engine picks the language.
    func supports(language: String) -> Bool {
        guard let code = languageCode(language), let languages else { return true }
        return languages.contains(code)
    }
}

/// Below this many tokens left for the answer, a chat request is treated as too long.
private let minimumAnswerTokens = 16
/// Models nobody used for this long are unloaded, giving their memory back.
private let idleUnloadAfter = Duration.seconds(10 * 60)

/// Tokens left for the answer once the prompt uses `used` of `contextSize`, at most `wanted`. Fails
/// rather than letting the model truncate the answer.
func answerBudget(used: Int, contextSize: Int, wanted: Int, modelName: String) throws -> Int {
    let left = contextSize - used
    if left < minimumAnswerTokens {
        throw ModelError.contextExceeded("Too long for \(modelName) (\(used) of \(contextSize) tokens)")
    }
    return min(wanted, left)
}

/// The language part of a setting like `de` or `pt-BR`, or nil when it's empty.
func languageCode(_ language: String) -> String? {
    let code = language.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "-" || $0 == "_" }).first
    return code.map { $0.lowercased() }
}

func languageName(_ code: String) -> String {
    Locale.current.localizedString(forLanguageCode: code) ?? code
}

/// One engine per downloaded model folder, so every request for a model shares one load.
final class EnginesByFolder<Engine: Sendable>: Sendable {
    private let engines = Mutex<[URL: Engine]>([:])

    func engine(for model: DownloadedModel, create: (DownloadedModel) -> Engine) -> Engine {
        engines.withLock { engines in
            if let engine = engines[model.folder] { return engine }
            let engine = create(model)
            engines[model.folder] = engine
            return engine
        }
    }

    /// Forgets the folder's engine, which holds what its manifest said when it was created; returns it to unload.
    func evict(_ folder: URL) -> Engine? {
        engines.withLock { $0.removeValue(forKey: folder) }
    }

    func evictAll() -> [Engine] {
        engines.withLock { engines in
            defer { engines = [:] }
            return Array(engines.values)
        }
    }
}

/// A model the app downloaded into `<models dir>/<id>/`, as described by its manifest.
struct DownloadedModel: Sendable {
    let entry: ModelEntry
    let folder: URL

    var id: String { entry.id }
    var name: String { entry.name }

    /// Only installed models count; a model mid-download or paused has an incomplete folder.
    static func installed(_ id: String, in modelsDirectory: URL) throws -> DownloadedModel {
        let folder = try folder(id, in: modelsDirectory)
        guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data)
        else { throw ModelError.unavailable("The model \(id) isn't downloaded. Download it in Settings → Models") }
        guard manifest.installed else {
            throw ModelError.unavailable("\(manifest.entry.name) hasn't finished downloading. Finish it in Settings → Models")
        }
        return DownloadedModel(entry: manifest.entry, folder: folder)
    }

    /// Where the model `id` lives, whether or not it's downloaded.
    static func folder(_ id: String, in modelsDirectory: URL) throws -> URL {
        guard !id.isEmpty, !id.contains("/"), id != "..", id != "." else { throw ModelError.unavailable("Unknown model \(id)") }
        return modelsDirectory.appending(path: id, directoryHint: .isDirectory)
    }
}

/// Counts requests in flight and unloads every model once none ran for `idleUnloadAfter`.
private actor IdleUnloader {
    private var inFlight = 0
    private var timer: Task<Void, Never>?
    private let unload: @Sendable () async -> Void

    init(unload: @escaping @Sendable () async -> Void) {
        self.unload = unload
    }

    func begin() {
        inFlight += 1
        timer?.cancel()
        timer = nil
    }

    func end() {
        inFlight -= 1
        guard inFlight == 0 else { return }
        let unload = unload
        timer = Task {
            try? await Task.sleep(for: idleUnloadAfter)
            guard !Task.isCancelled else { return }
            await unload()
        }
    }
}

/// Runs Built-in models in the app's process: Apple's on-device speech-to-text and chat model, and
/// downloaded WhisperKit, Parakeet and MLX models read from their folders.
public final class LocalEngines: BuiltInEngines {
    private let modelsDirectory: URL
    private let appleSpeech: AppleSpeech
    private let appleChat = AppleChat()
    private let whisper = EnginesByFolder<WhisperKitEngine>()
    private let mlxWhisper = EnginesByFolder<MLXWhisperEngine>()
    private let parakeet = Parakeet()
    private let mlxChat = EnginesByFolder<MLXChatEngine>()
    private let idle: IdleUnloader

    /// `onProgress` hears Apple language-asset downloads.
    public init(modelsDirectory: URL, requestsSpeechAuthorization: Bool = true, onProgress: @escaping @Sendable (ModelProgress) async -> Void) {
        self.modelsDirectory = modelsDirectory
        let reporter = ProgressThrottle(onProgress)
        appleSpeech = AppleSpeech(requestsAuthorization: requestsSpeechAuthorization) { locale, fraction in
            await reporter.report(locale: locale, fraction: fraction)
        }
        idle = IdleUnloader { [appleSpeech, whisper, mlxWhisper, mlxChat, parakeet] in
            await Self.unloadAll(appleSpeech: appleSpeech, whisper: whisper, mlxWhisper: mlxWhisper, mlxChat: mlxChat, parakeet: parakeet)
        }
    }

    public func transcribe(model: String, wav: Data, language: String, prompt: String, segments: Bool) async throws -> EngineTranscription {
        try await tracked {
            let engine = try self.speechToText(model)
            let audio: DecodedAudio
            do { audio = try decodeWav(wav) } catch { throw ModelError.modelFailed(errorMessage(error)) }
            guard audio.sampleRate == speechSampleRate else {
                throw ModelError.modelFailed("Audio must be 16 kHz (got \(audio.sampleRate) Hz)")
            }
            let parts = try await engine.transcribe(audio.samples, language: language, prompt: prompt)
            return EngineTranscription(text: parts.map(\.text).joined(), segments: segments ? parts : nil)
        }
    }

    public func complete(model: String, messages: [ChatMessage], maxTokens: Int) async throws -> String {
        try await tracked { try await self.chat(model).complete(messages, maxTokens: maxTokens) }
    }

    public func load(_ models: [ModelRef]) async throws {
        try await tracked {
            for model in models {
                switch model.role {
                case .speechToText: try await self.speechToText(model.id).load(language: model.language)
                case .chat: try await self.chat(model.id).load()
                }
            }
        }
    }

    public func unload(_ models: [String]) async throws {
        for id in models {
            if id == appleModelId {
                await appleSpeech.unload()
                continue
            }
            // By folder, not manifest: a model being replaced or removed may no longer count as installed.
            guard let folder = try? DownloadedModel.folder(id, in: modelsDirectory) else { continue }
            await whisper.evict(folder)?.unload()
            await mlxWhisper.evict(folder)?.unload()
            await mlxChat.evict(folder)?.unload()
            await parakeet.unload(folder)
        }
    }

    public func status(language: String, speechToText: String?, chat: String?) async throws -> BuiltInStatus {
        BuiltInStatus(
            appleSpeech: await appleSpeech.status(language: language),
            appleChat: appleChat.status(),
            speechToText: speechToText.flatMap { try? downloadedSpeechStatus($0, language: language) },
            chat: chat.flatMap { try? downloadedChatStatus($0) }
        )
    }

    public func stop() async {
        await Self.unloadAll(appleSpeech: appleSpeech, whisper: whisper, mlxWhisper: mlxWhisper, mlxChat: mlxChat, parakeet: parakeet)
    }

    private static func unloadAll(
        appleSpeech: AppleSpeech, whisper: EnginesByFolder<WhisperKitEngine>, mlxWhisper: EnginesByFolder<MLXWhisperEngine>,
        mlxChat: EnginesByFolder<MLXChatEngine>, parakeet: Parakeet
    ) async {
        await appleSpeech.unload()
        for engine in whisper.evictAll() { await engine.unload() }
        for engine in mlxWhisper.evictAll() { await engine.unload() }
        for engine in mlxChat.evictAll() { await engine.unload() }
        await parakeet.unloadAll()
    }

    private func tracked<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        await idle.begin()
        do {
            let result = try await body()
            await idle.end()
            return result
        } catch let error as ModelError {
            await idle.end()
            throw error
        } catch {
            await idle.end()
            let nsError = error as NSError
            // SFSpeechError.noModel: the locale isn't supported after all.
            if nsError.domain == "SFSpeechErrorDomain" && nsError.code == 4 {
                throw ModelError.unsupportedLanguage("Apple's speech-to-text doesn't support this language")
            }
            throw ModelError.modelFailed(nsError.localizedDescription)
        }
    }

    private func speechToText(_ model: String) throws -> any SpeechToTextEngine {
        if model == appleModelId { return appleSpeech }
        return try speechToText(try DownloadedModel.installed(model, in: modelsDirectory))
    }

    private func speechToText(_ model: DownloadedModel) throws -> any SpeechToTextEngine {
        guard model.entry.task == .speechToText else { throw ModelError.unavailable("\(model.name) isn't a speech-to-text model") }
        switch model.entry.engine {
        case .fluidAudio: return ParakeetEngine(model: model, parakeet: parakeet)
        case .whisperKit: return whisper.engine(for: model, create: WhisperKitEngine.init)
        case .mlxWhisper: return mlxWhisper.engine(for: model, create: MLXWhisperEngine.init)
        case .mlx: throw ModelError.unavailable("\(model.name) can't be used for speech-to-text")
        }
    }

    private func chat(_ model: String) throws -> any ChatEngine {
        if model == appleModelId { return appleChat }
        let downloaded = try DownloadedModel.installed(model, in: modelsDirectory)
        guard downloaded.entry.task == .chat else { throw ModelError.unavailable("\(downloaded.name) isn't a chat model") }
        switch downloaded.entry.engine {
        case .mlx: return mlxChat.engine(for: downloaded, create: MLXChatEngine.init)
        case .whisperKit, .fluidAudio, .mlxWhisper: throw ModelError.unavailable("\(downloaded.name) can't be used for chat")
        }
    }

    private func downloadedChatStatus(_ id: String) throws -> BuiltInStatus.DownloadedChat {
        let model = try DownloadedModel.installed(id, in: modelsDirectory)
        guard model.entry.task == .chat, model.entry.engine == .mlx else { throw ModelError.unavailable("\(model.name) can't be used for chat") }
        return BuiltInStatus.DownloadedChat(model: id, name: model.name, contextSize: try MLXChatEngine.contextSize(of: model))
    }

    private func downloadedSpeechStatus(_ id: String, language: String) throws -> BuiltInStatus.DownloadedSpeech {
        let model = try DownloadedModel.installed(id, in: modelsDirectory)
        let engine = try speechToText(model)
        return BuiltInStatus.DownloadedSpeech(model: id, name: model.name, supported: engine.supports(language: language), languages: engine.languages)
    }
}

/// Passes on a download's progress, skipping updates of less than a percent.
private actor ProgressThrottle {
    private let send: @Sendable (ModelProgress) async -> Void
    private var reported: [String: Double] = [:]

    init(_ send: @escaping @Sendable (ModelProgress) async -> Void) {
        self.send = send
    }

    func report(locale: String, fraction: Double) async {
        if let last = reported[locale], fraction <= last || (fraction < 1 && fraction - last < 0.01) { return }
        reported[locale] = fraction
        await send(.appleSpeechAssets(locale: locale, fraction: fraction))
    }
}
