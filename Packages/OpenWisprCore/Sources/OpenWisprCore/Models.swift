import Foundation
import Observation

/// A model to have ready before it's needed. `id` is `appleModelId` or a downloaded model's id.
public struct ModelRef: Sendable, Equatable {
    public var role: ModelRole
    public var id: String
    public var language: String

    public init(role: ModelRole, id: String, language: String) {
        self.role = role
        self.id = id
        self.language = language
    }
}

/// What a Built-in speech-to-text model heard. Segment times are seconds from the start of the audio.
public struct EngineTranscription: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public var text: String
    /// Present when segments were asked for.
    public var segments: [Segment]?

    public init(text: String, segments: [Segment]? = nil) {
        self.text = text
        self.segments = segments
    }
}

/// Runs Built-in models: Apple's on-device ones, and downloaded ones from their folders. Errors are `ModelError`s.
public protocol BuiltInEngines: Sendable {
    func transcribe(model: String, wav: Data, language: String, prompt: String, segments: Bool) async throws -> EngineTranscription
    func complete(model: String, messages: [ChatMessage], maxTokens: Int) async throws -> String
    func load(_ models: [ModelRef]) async throws
    func unload(_ models: [String]) async throws
    /// `speechToText` and `chat` are the selected downloaded models, if any.
    func status(language: String, speechToText: String?, chat: String?) async throws -> BuiltInStatus
    /// Unloads everything.
    func stop() async
}

public enum Availability: Sendable, Equatable {
    case available
    case unavailable(String)

    public var reason: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

public struct CleanupResult: Sendable, Equatable {
    public var text: String
    /// Why Cleanup didn't run, for the Flow bar; nil when it ran or the transcript was kept quietly.
    public var notice: String?
}

public enum EndpointTestResult: Sendable, Equatable {
    case ok
    case failed(String)
}

private let builtInUnavailable = "Built-in models are not available yet"
private let testTimeout: TimeInterval = 20
public let defaultMaxTokens = 1024
/// Loads that take longer are compiling the model for this Mac, which the first use of a Core ML model does.
private let preparingAfter = Duration.seconds(1)
/// A model needing more than this share of physical memory would likely make the Mac swap.
private let memoryShare = 0.6
/// How long removing or replacing a model waits for requests using it before unloading every model.
private let releaseTimeout = Duration.seconds(30)

private enum BuiltInSelection {
    case model(String)
    case unavailable(String)
}

func cleanupNotice(_ error: any Error) -> String? {
    guard let error = error as? ModelError else { return "Cleanup failed: \(errorMessage(error))" }
    switch error {
    case .refused: return nil
    case let .unavailable(message), let .unsupportedLanguage(message), let .contextExceeded(message): return "Cleanup skipped: \(message)"
    case let .modelFailed(message): return "Cleanup failed: \(message)"
    }
}

/// 16 kHz mono PCM16 silence.
func silentWav(durationMs: Double) -> Data {
    encodeWav(samples: [Float](repeating: 0, count: Int((16_000 * durationMs / 1000).rounded())), sampleRate: 16_000)
}

/// The only way Dictation and the Notetaker reach a speech-to-text or chat model.
@Observable
@MainActor
public final class Models {
    /// Recommended models and the ones the user added, with their download state and disk usage.
    public private(set) var library = ModelLibraryState(models: [], diskUsageBytes: 0, physicalMemoryBytes: 0)
    /// The latest Apple asset download or slow first load, while one runs.
    public private(set) var progress: ModelProgress?
    /// Models in the Hugging Face cache OpenWispr can run, as of the last `refreshCachedModels`.
    private var cached: [CachedModel] = []

    @ObservationIgnored public var onProgress: ((ModelProgress) -> Void)?
    @ObservationIgnored private let settings: () -> Settings
    @ObservationIgnored private let engines: any BuiltInEngines
    @ObservationIgnored private let endpoints: EndpointClient
    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored private let physicalMemoryBytes: Int64
    @ObservationIgnored private let hubCache: HubCache?
    @ObservationIgnored private var downloads: ModelDownloads!
    @ObservationIgnored private var installed: [String: ModelManifest] = [:]
    @ObservationIgnored private var loads: [String: Task<Void, any Error>] = [:]
    @ObservationIgnored private var preparing: Set<String> = []
    /// Engine requests in flight, by the downloaded model they read.
    @ObservationIgnored private var inUse: [String: Int] = [:]
    /// Models whose files are being replaced or deleted, which take no new requests.
    @ObservationIgnored private var releasing: Set<String> = []
    @ObservationIgnored private var libraryRefresh: Task<Void, Never>?
    @ObservationIgnored private var cacheScan: Task<Void, Never>?

    public init(
        settings: @escaping () -> Settings, engines: any BuiltInEngines, http: any HTTPClient, modelsDirectory: URL,
        hubCache: HubCache? = nil, physicalMemoryBytes: Int64 = Int64(ProcessInfo.processInfo.physicalMemory),
        retryDelay: Duration = .seconds(2)
    ) {
        self.settings = settings
        self.engines = engines
        self.http = http
        endpoints = EndpointClient(http: http)
        self.physicalMemoryBytes = physicalMemoryBytes
        self.hubCache = hubCache
        downloads = ModelDownloads(
            directory: modelsDirectory, http: http, hubCache: hubCache, retryDelay: retryDelay,
            onChange: { [weak self] in Task { @MainActor in self?.libraryChanged() } },
            release: { [weak self] id in await self?.release(id) }
        )
    }

    /// Reads the installed models, which `availability` relies on, and the library.
    public func refresh() async {
        await refreshInstalled()
        await refreshLibrary()
    }

    /// Runnable models in the Hugging Face cache that aren't in the library yet, ready to add without a download.
    public var cachedModels: [CachedModel] {
        cached.filter { found in !library.models.contains { $0.model.id == found.id } }
    }

    /// Looks through the Hugging Face cache again, reading only its small config files. A call during a scan
    /// waits for that scan rather than starting another, so an older result never replaces a newer one.
    public func refreshCachedModels() async {
        guard let hubCache else { return }
        if let cacheScan { return await cacheScan.value }
        let memory = physicalMemoryBytes
        let scan = Task {
            let found = await discoverCachedModels(hubCache)
            cached = found.map {
                CachedModel(model: $0.model, summary: $0.summary, oversized: Double($0.model.memoryBytes) > Double(memory) * memoryShare)
            }
            cacheScan = nil
        }
        cacheScan = scan
        await scan.value
    }

    public func refreshLibrary() async {
        let memory = physicalMemoryBytes
        var models: [ModelStatus] = []
        let added = await downloads.manifests().filter(\.userAdded)
        for (model, userAdded) in recommendedModels.map({ ($0, false) }) + added.map({ ($0.entry, true) }) {
            models.append(ModelStatus(
                model: model, recommended: !userAdded, userAdded: userAdded,
                oversized: Double(model.memoryBytes) > Double(memory) * memoryShare,
                state: await downloads.state(model.id), preparing: preparing.contains(model.id)
            ))
        }
        library = ModelLibraryState(models: models, diskUsageBytes: await downloads.diskUsage(), physicalMemoryBytes: memory)
    }

    /// Downloads or resumes a Recommended model; returns once installed or cancelled. An installed
    /// speech-to-text model is then loaded, so the slow first load doesn't land on its first dictation.
    public func download(_ id: String) async throws {
        if let recommended = recommendedModels.first(where: { $0.id == id }) { return try await install(recommended, userAdded: false) }
        guard let added = await downloads.manifests().first(where: { $0.entry.id == id && $0.userAdded }) else {
            throw AppError("Unknown model \(id)")
        }
        try await install(added.entry, userAdded: true)
    }

    /// Checks a pasted Hugging Face repo id or URL without downloading any weights.
    public func checkRepo(_ input: String) async -> RepoCheck {
        switch await checkHubRepo(HuggingFace(http: http), input) {
        case let .compatible(model, summary):
            .compatible(model: model, summary: summary, oversized: Double(model.memoryBytes) > Double(physicalMemoryBytes) * memoryShare)
        case let .severalModels(repo, revision, folders, message):
            .severalModels(repo: repo, revision: revision, folders: folders, message: message)
        case let .rejected(reason, message):
            .rejected(reason: reason, message: message)
        }
    }

    /// Downloads a model `checkRepo` accepted; it's listed as added by the user, and resumes like a Recommended one.
    public func addModel(_ model: ModelEntry) async throws {
        try await install(model, userAdded: true)
    }

    /// Stops a download and discards what it fetched.
    public func cancelDownload(_ id: String) async throws {
        defer { releasing.remove(id) }
        do {
            try await downloads.cancel(id)
        } catch {
            await refreshInstalled()
            throw error
        }
        await refreshInstalled()
    }

    /// Deletes a downloaded model; returns the bytes freed. The selected model of a role can't be removed.
    @discardableResult
    public func removeModel(_ id: String) async throws -> Int64 {
        let current = settings()
        if let role = ModelRole.allCases.first(where: { current[$0].builtInModelId == id }) {
            let name = installed[id]?.entry.name ?? id
            throw AppError("\(name) is selected for \(role.name). Choose another model in Settings before removing it")
        }
        defer { releasing.remove(id) }
        do {
            let freed = try await downloads.remove(id)
            await refreshInstalled()
            return freed
        } catch {
            await refreshInstalled()
            throw error
        }
    }

    /// Whether `role` can be used right now. A chat Endpoint needs no key, since local servers don't ask
    /// for one; a cloud speech-to-text Endpoint does, so a fresh install asks for one before recording.
    public func availability(_ role: ModelRole) -> Availability {
        guard let config = settings().resolvedEndpoint(role) else {
            if case let .unavailable(reason) = builtIn(role) { return .unavailable(reason) }
            return .available
        }
        switch role {
        case .speechToText:
            if config.baseUrl.trimmed.isEmpty || config.model.trimmed.isEmpty { return .unavailable("Set up a speech-to-text model in Settings") }
            if config.apiKey.isEmpty && !isLocalEndpoint(config.baseUrl) { return .unavailable("Add a speech-to-text API key in Settings") }
            return .available
        case .chat:
            if config.baseUrl.trimmed.isEmpty || config.model.trimmed.isEmpty { return .unavailable("Set up a chat model in Settings") }
            return .available
        }
    }

    public func transcribe(_ wav: Data, prompt: String) async throws -> String {
        if let model = try builtInSpeechModel() {
            return try await transcribeBuiltIn(model, wav, prompt: prompt, segments: false).text.trimmed
        }
        return try await endpoints.transcribe(try endpoint(.speechToText), language: settings().language, wav: wav, prompt: prompt)
    }

    /// A dictation has started: have the selected Built-in models loaded by the time its audio arrives.
    public func warmUp() {
        let language = settings().language
        let speechModel: String? = if case let .model(id) = builtIn(.speechToText) { id } else { nil }
        if let speechModel, speechModel != appleModelId { prepareInBackground(.speechToText, speechModel) }
        let chat = builtInChatModel()
        if let chat, chat != appleModelId { prepareInBackground(.chat, chat) }
        var refs: [ModelRef] = []
        if speechModel == appleModelId { refs.append(ModelRef(role: .speechToText, id: appleModelId, language: language)) }
        if chat == appleModelId { refs.append(ModelRef(role: .chat, id: appleModelId, language: language)) }
        guard !refs.isEmpty else { return }
        Task { [engines] in
            do { try await engines.load(refs) } catch { print("openwispr: warm-up failed: \(error)") }
        }
    }

    /// Like `transcribe`, but keeps segment timing and, for diarizing Endpoints, speaker labels.
    public func transcribeSegments(_ wav: Data, durationMs: Double, prompt: String, known: KnownSpeakers? = nil) async throws -> [TranscriptSegment] {
        if let model = try builtInSpeechModel() {
            let result = try await transcribeBuiltIn(model, wav, prompt: prompt, segments: true)
            let segments = result.segments?.map { TranscriptionResponse.Segment(start: $0.start, end: $0.end, text: $0.text, speaker: nil) }
            return parseSegments(TranscriptionResponse(text: result.text, segments: segments), durationMs: durationMs)
        }
        return try await endpoints.transcribeSegments(
            try endpoint(.speechToText), language: settings().language, wav: wav, durationMs: durationMs, prompt: prompt, known: known
        )
    }

    /// Apple's models on this Mac and, for a selected downloaded speech-to-text model, its languages; each
    /// says whether it supports the language setting.
    public func status() async throws -> BuiltInStatus {
        let speechModel: String? = if case let .model(id) = builtIn(.speechToText), id != appleModelId { id } else { nil }
        let chat = builtInChatModel().flatMap { $0 == appleModelId ? nil : $0 }
        return try await engines.status(language: settings().language, speechToText: speechModel, chat: chat)
    }

    /// How many tokens a chat request and its answer may use together, or nil when unknown, as for Endpoints.
    public func chatContextSize() async -> Int? {
        guard let chat = builtInChatModel(), let status = try? await status() else { return nil }
        return chat == appleModelId ? status.appleChat.contextSize : status.chat?.contextSize
    }

    /// Unloads every Built-in model; the next request loads it again.
    public func stop() async {
        await engines.stop()
    }

    /// `maxTokens` caps the answer of Built-in models, which fail rather than cut it off.
    public func complete(_ messages: [ChatMessage], label: String = "Cleanup", timeout: TimeInterval = EndpointClient.timeout, maxTokens: Int = defaultMaxTokens) async throws -> String {
        switch builtIn(.chat) {
        case nil:
            return try await endpoints.complete(try endpoint(.chat), messages: messages, label: label, timeout: timeout)
        case let .unavailable(reason):
            throw ModelError.unavailable(reason)
        case let .model(model):
            return try await using(model) { engines in try await engines.complete(model: model, messages: messages, maxTokens: maxTokens) }.trimmed
        }
    }

    /// Cleans up a Dictation's (dictionary-corrected) transcript. When the chat model is unavailable,
    /// fails, refuses or answers instead of formatting, the transcript is kept as it is; `notice` says
    /// why when the user should know.
    public func cleanup(_ input: CleanupInput) async -> CleanupResult {
        do {
            let output = try await complete(cleanupMessages(input), label: "Chat", maxTokens: cleanupMaxTokens(input.transcript))
            return CleanupResult(text: sanitizeCleanup(output, transcript: input.transcript, beforeText: input.beforeText), notice: nil)
        } catch {
            return CleanupResult(text: input.transcript, notice: cleanupNotice(error))
        }
    }

    /// Sends the selected Endpoint for `role` a tiny real request.
    public func testEndpoint(_ role: ModelRole) async -> EndpointTestResult {
        do {
            switch role {
            case .speechToText:
                _ = try await endpoints.transcribe(try endpoint(role), language: "", wav: silentWav(durationMs: 500), prompt: "")
            case .chat:
                _ = try await endpoints.complete(try endpoint(role), messages: [.user("Reply with OK.")], label: "Chat", timeout: testTimeout)
            }
            return .ok
        } catch {
            return .failed(errorMessage(error))
        }
    }

    private func endpoint(_ role: ModelRole) throws -> EndpointConfig {
        guard let config = settings().resolvedEndpoint(role) else { throw AppError(builtInUnavailable) }
        return config
    }

    private func transcribeBuiltIn(_ model: String, _ wav: Data, prompt: String, segments: Bool) async throws -> EngineTranscription {
        let language = settings().language
        do {
            return try await using(model) { engines in
                try await engines.transcribe(model: model, wav: wav, language: language, prompt: prompt, segments: segments)
            }
        } catch let ModelError.unsupportedLanguage(message) {
            let isWhisper = [.whisperKit, .mlxWhisper].contains(installed[model]?.entry.engine)
            let hint = isWhisper ? "Choose another language" : "Download a Whisper model or choose another language"
            throw ModelError.unsupportedLanguage("\(message). \(hint) in Settings")
        }
    }

    /// The Built-in speech-to-text model to use, or nil when an Endpoint is selected; throws when it can't be used.
    private func builtInSpeechModel() throws -> String? {
        switch builtIn(.speechToText) {
        case nil: return nil
        case let .unavailable(reason): throw AppError(reason)
        case let .model(id): return id
        }
    }

    /// The selected Built-in model for `role`, or why it can't be used; nil when an Endpoint is selected.
    private func builtIn(_ role: ModelRole) -> BuiltInSelection? {
        guard let id = settings()[role].builtInModelId else { return nil }
        if id == appleModelId { return .model(appleModelId) }
        let manifest = installed[id]
        if releasing.contains(id) { return .unavailable("\(manifest?.entry.name ?? id) is being updated or removed") }
        guard let manifest else {
            let name = recommendedModels.first { $0.id == id }?.name ?? id
            return .unavailable("\(name) isn't downloaded. Download it or choose another \(role.name) model in Settings")
        }
        if manifest.entry.task != ModelTask(role) { return .unavailable("\(manifest.entry.name) isn't a \(role.name) model") }
        if !manifest.entry.isRunnable {
            return .unavailable("\(manifest.entry.name) needs an engine OpenWispr doesn't have yet. Choose another \(role.name) model in Settings")
        }
        return .model(id)
    }

    /// The selected Built-in chat model when it can be used.
    private func builtInChatModel() -> String? {
        if case let .model(id) = builtIn(.chat) { return id }
        return nil
    }

    private func prepareInBackground(_ role: ModelRole, _ id: String) {
        Task {
            do { try await prepare(role, id) } catch { print("openwispr: preparing \(id) failed: \(error)") }
        }
    }

    /// Loads a downloaded model, reporting it as preparing while a slow first load runs.
    private func prepare(_ role: ModelRole, _ id: String) async throws {
        if let running = loads[id] { return try await running.value }
        let name = installed[id]?.entry.name ?? id
        let language = settings().language
        let timer = Task {
            try await Task.sleep(for: preparingAfter)
            setPreparing(id, name: name, true)
        }
        let load = Task {
            defer {
                timer.cancel()
                loads[id] = nil
                if preparing.contains(id) { setPreparing(id, name: name, false) }
            }
            try await using(id) { engines in try await engines.load([ModelRef(role: role, id: id, language: language)]) }
        }
        loads[id] = load
        try await load.value
    }

    private func setPreparing(_ modelId: String, name: String, _ isPreparing: Bool) {
        if isPreparing { preparing.insert(modelId) } else { preparing.remove(modelId) }
        report(.preparingModel(modelId: modelId, name: name, preparing: isPreparing))
        libraryChanged()
    }

    /// Shows engine progress, such as an Apple speech asset download, in the hub and the Flow bar.
    public func report(_ update: ModelProgress) {
        progress = update.isOngoing ? update : nil
        onProgress?(update)
    }

    private func install(_ model: ModelEntry, userAdded: Bool) async throws {
        do {
            try await downloads.start(model, userAdded: userAdded)
        } catch {
            await refreshInstalled()
            releasing.remove(model.id)
            throw error
        }
        await refreshInstalled()
        releasing.remove(model.id)
        if let manifest = installed[model.id], manifest.entry.task == .speechToText, manifest.entry.isRunnable {
            prepareInBackground(.speechToText, model.id)
        }
    }

    /// Runs an engine request that reads model `id`'s files, tracked so `release` can wait for it.
    private func using<T: Sendable>(_ id: String, _ body: @Sendable (any BuiltInEngines) async throws -> T) async throws -> T {
        inUse[id, default: 0] += 1
        defer {
            inUse[id, default: 1] -= 1
            if inUse[id] == 0 { inUse[id] = nil }
        }
        return try await body(engines)
    }

    /// Waits for requests using the model to finish, then has the engines unload it and forget what the
    /// manifest said; a reinstall under this id then loads afresh.
    private func release(_ id: String) async {
        releasing.insert(id)
        let deadline = ContinuousClock.now + releaseTimeout
        while inUse[id] != nil {
            if ContinuousClock.now >= deadline {
                print("openwispr: requests using \(id) didn't finish; unloading every model")
                await engines.stop()
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        do {
            try await engines.unload([id])
        } catch {
            print("openwispr: unloading \(id) failed; unloading every model instead: \(error)")
            await engines.stop()
        }
    }

    private func libraryChanged() {
        guard libraryRefresh == nil else { return }
        libraryRefresh = Task {
            await refreshLibrary()
            libraryRefresh = nil
        }
    }

    private func refreshInstalled() async {
        let manifests = await downloads.manifests()
        installed = Dictionary(manifests.filter(\.installed).map { ($0.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
        libraryChanged()
    }
}
