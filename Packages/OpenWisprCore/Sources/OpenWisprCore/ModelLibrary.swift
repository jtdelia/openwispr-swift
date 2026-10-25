import Foundation

/// Vision models are listed for Lens, which comes later.
public enum ModelTask: String, Sendable, Codable, CaseIterable {
    case speechToText, chat, vision

    public init(_ role: ModelRole) {
        switch role {
        case .speechToText: self = .speechToText
        case .chat: self = .chat
        }
    }
}

/// `mlxWhisper` runs Whisper checkpoints in Transformers format, like OpenAI's own repos, with MLX.
public enum ModelEngine: String, Sendable, Codable {
    case whisperKit, fluidAudio, mlx, mlxWhisper

    public var label: String {
        switch self {
        case .whisperKit: "WhisperKit"
        case .fluidAudio: "FluidAudio"
        case .mlx: "MLX"
        case .mlxWhisper: "Whisper on MLX"
        }
    }
}

/// Engines OpenWispr can run, per task; installed models of other engines can't be selected yet.
public func runnableEngines(_ task: ModelTask) -> [ModelEngine] {
    switch task {
    case .speechToText: [.whisperKit, .fluidAudio, .mlxWhisper]
    case .chat: [.mlx]
    case .vision: []
    }
}

public enum SpeedTier: String, Sendable, Codable {
    case fastest, fast, medium, slow

    public var label: String {
        switch self {
        case .fastest: "Fastest"
        case .fast: "Fast"
        case .medium: "Medium"
        case .slow: "Slow"
        }
    }
}

/// Files to fetch from one Hugging Face repo at a pinned commit. With `folder`, only that folder is fetched
/// and its contents land at the model's root; with `files`, only those paths (a trailing `/` takes a whole
/// folder); with neither, the whole repo minus docs and images.
public struct ModelSource: Sendable, Equatable, Codable {
    public var repo: String
    /// Commit sha.
    public var revision: String
    public var folder: String?
    public var files: [String]?

    public init(repo: String, revision: String, folder: String? = nil, files: [String]? = nil) {
        self.repo = repo
        self.revision = revision
        self.folder = folder
        self.files = files
    }
}

/// A Built-in model OpenWispr can download: a Recommended model, or one the user added.
public struct ModelEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var task: ModelTask
    public var engine: ModelEngine
    /// More than one when an engine needs files from a second repo, like WhisperKit's tokenizer.
    public var sources: [ModelSource]
    /// Approximate; the real total comes from the Hugging Face listing.
    public var sizeBytes: Int64
    /// Rough resident memory while loaded.
    public var memoryBytes: Int64
    public var speed: SpeedTier
    /// For display, like "99 languages".
    public var languages: String
    /// ISO codes when the set is small and known; nil for broadly multilingual models.
    public var languageCodes: [String]?
    /// Extra chat template variables the engine must pass, like `enable_thinking: false`.
    public var chatTemplateContext: [String: Bool]?

    public init(
        id: String, name: String, task: ModelTask, engine: ModelEngine, sources: [ModelSource], sizeBytes: Int64,
        memoryBytes: Int64, speed: SpeedTier, languages: String, languageCodes: [String]?, chatTemplateContext: [String: Bool]? = nil
    ) {
        self.id = id
        self.name = name
        self.task = task
        self.engine = engine
        self.sources = sources
        self.sizeBytes = sizeBytes
        self.memoryBytes = memoryBytes
        self.speed = speed
        self.languages = languages
        self.languageCodes = languageCodes
        self.chatTemplateContext = chatTemplateContext
    }

    public var isRunnable: Bool { runnableEngines(task).contains(engine) }
}

public enum DownloadState: Sendable, Equatable {
    case notDownloaded
    case downloading(bytesDone: Int64, totalBytes: Int64, bytesPerSecond: Double)
    /// Interrupted (quit, or retries ran out) with partial files kept, so it resumes where it stopped.
    case paused(bytesDone: Int64, totalBytes: Int64, error: String?)
    case installed(sizeBytes: Int64)

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

public struct ModelStatus: Sendable, Equatable, Identifiable {
    public var model: ModelEntry
    public var recommended: Bool
    public var userAdded: Bool
    /// Its memory estimate exceeds about 60% of this Mac's memory, so it would likely thrash.
    public var oversized: Bool
    public var state: DownloadState
    /// Installed and loading for the first time, which compiles it for this Mac and can take minutes.
    public var preparing: Bool

    public var id: String { model.id }

    public init(model: ModelEntry, recommended: Bool, userAdded: Bool, oversized: Bool, state: DownloadState, preparing: Bool) {
        self.model = model
        self.recommended = recommended
        self.userAdded = userAdded
        self.oversized = oversized
        self.state = state
        self.preparing = preparing
    }
}

/// The model to offer in one click for `role` (optionally of one `engine`): an installed one OpenWispr
/// can run, or else the first Recommended one this Mac has the memory for.
public func offeredModel(_ models: [ModelStatus], role: ModelRole, engine: ModelEngine? = nil) -> ModelStatus? {
    let candidates = models.filter { $0.model.task == ModelTask(role) && $0.model.isRunnable && (engine == nil || $0.model.engine == engine) }
    return candidates.first { $0.state.isInstalled } ?? candidates.first { $0.recommended && !$0.oversized }
}

/// Why a Hugging Face repo can't be added. Without an account, Hugging Face answers a private repo exactly
/// like a missing one, so the two share `notFoundOrPrivate`.
public enum RepoRejection: String, Sendable, Equatable {
    case invalidReference, notFoundOrPrivate, gated, ggufOnly, notMlx, unsupportedArchitecture, missingFiles, alreadyListed, hubFailed
}

/// The compatibility check of a pasted repo id or URL, made before anything is downloaded.
public enum RepoCheck: Sendable, Equatable {
    /// `oversized` as in `ModelStatus`.
    case compatible(model: ModelEntry, summary: String, oversized: Bool)
    /// A repo holding several speech-to-text models, like WhisperKit's; one folder must be chosen.
    case severalModels(repo: String, revision: String, folders: [String], message: String)
    case rejected(reason: RepoRejection, message: String)
}

public struct ModelLibraryState: Sendable, Equatable {
    public var models: [ModelStatus]
    /// Everything under the models folder, partial downloads included.
    public var diskUsageBytes: Int64
    public var physicalMemoryBytes: Int64

    public init(models: [ModelStatus], diskUsageBytes: Int64, physicalMemoryBytes: Int64) {
        self.models = models
        self.diskUsageBytes = diskUsageBytes
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}
