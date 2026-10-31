import Foundation

public enum ShortcutAction: String, CaseIterable, Sendable, Codable {
    case ptt, handsFree, pasteLast, copyLast

    public var label: String {
        switch self {
        case .ptt: "Push to talk (hold)"
        case .handsFree: "Hands-free mode"
        case .pasteLast: "Paste last transcript"
        case .copyLast: "Copy last transcript"
        }
    }
}

public struct Shortcuts: Sendable, Equatable, Codable {
    public var ptt: [Int]
    public var handsFree: [Int]
    public var pasteLast: [Int]
    public var copyLast: [Int]

    public init(ptt: [Int], handsFree: [Int], pasteLast: [Int], copyLast: [Int]) {
        self.ptt = ptt
        self.handsFree = handsFree
        self.pasteLast = pasteLast
        self.copyLast = copyLast
    }

    public static let defaults = Shortcuts(
        ptt: [Key.fn],
        handsFree: [Key.fn, Key.space],
        pasteLast: [Key.ctrl, Key.cmd, Key.v],
        copyLast: [Key.ctrl, Key.cmd, Key.c]
    )

    public subscript(action: ShortcutAction) -> [Int] {
        get {
            switch action {
            case .ptt: ptt
            case .handsFree: handsFree
            case .pasteLast: pasteLast
            case .copyLast: copyLast
            }
        }
        set {
            switch action {
            case .ptt: ptt = newValue
            case .handsFree: handsFree = newValue
            case .pasteLast: pasteLast = newValue
            case .copyLast: copyLast = newValue
            }
        }
    }

    public var all: [[Int]] { ShortcutAction.allCases.map { self[$0] } }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Shortcuts.defaults
        ptt = try container.decodeIfPresent([Int].self, forKey: .ptt) ?? defaults.ptt
        handsFree = try container.decodeIfPresent([Int].self, forKey: .handsFree) ?? defaults.handsFree
        pasteLast = try container.decodeIfPresent([Int].self, forKey: .pasteLast) ?? defaults.pasteLast
        copyLast = try container.decodeIfPresent([Int].self, forKey: .copyLast) ?? defaults.copyLast
    }
}

public enum StyleContext: String, CaseIterable, Sendable, Codable {
    case personal, work, email, other
}

public enum Style: String, CaseIterable, Sendable, Codable {
    case formal, casual, veryCasual, excited
}

public struct Styles: Sendable, Equatable, Codable {
    public var personal: Style
    public var work: Style
    public var email: Style
    public var other: Style

    public init(personal: Style, work: Style, email: Style, other: Style) {
        self.personal = personal
        self.work = work
        self.email = email
        self.other = other
    }

    public static let defaults = Styles(personal: .casual, work: .casual, email: .formal, other: .casual)

    public subscript(context: StyleContext) -> Style {
        get {
            switch context {
            case .personal: personal
            case .work: work
            case .email: email
            case .other: other
            }
        }
        set {
            switch context {
            case .personal: personal = newValue
            case .work: work = newValue
            case .email: email = newValue
            case .other: other = newValue
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Styles.defaults
        personal = (try? container.decodeIfPresent(Style.self, forKey: .personal)) ?? defaults.personal
        work = (try? container.decodeIfPresent(Style.self, forKey: .work)) ?? defaults.work
        email = (try? container.decodeIfPresent(Style.self, forKey: .email)) ?? defaults.email
        other = (try? container.decodeIfPresent(Style.self, forKey: .other)) ?? defaults.other
    }
}

public enum AppCategory: String, Sendable, Codable {
    case email, ai, terminal, messaging, other
}

/// Self-hosted servers, on this Mac or the local network, usually don't require an API key.
public func isLocalEndpoint(_ baseUrl: String) -> Bool {
    guard let components = URLComponents(string: baseUrl.trimmed), ["http", "https"].contains(components.scheme?.lowercased()),
          let host = components.host?.lowercased() else { return false }
    if ["localhost", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") { return true }
    return host.matches(#"^(127|10)\.\d+\.\d+\.\d+$|^192\.168\.\d+\.\d+$|^172\.(1[6-9]|2\d|3[01])\.\d+\.\d+$"#)
}

public enum ModelRole: String, CaseIterable, Sendable, Codable {
    case speechToText, chat

    public var name: String {
        switch self {
        case .speechToText: "speech-to-text"
        case .chat: "chat"
        }
    }

    public var other: ModelRole { self == .chat ? .speechToText : .chat }
}

public struct EndpointConfig: Sendable, Equatable, Codable {
    public var baseUrl: String
    public var model: String
    /// Plaintext only in memory; persisted in the Keychain, never in the settings file.
    public var apiKey: String

    public init(baseUrl: String, model: String, apiKey: String) {
        self.baseUrl = baseUrl
        self.model = model
        self.apiKey = apiKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }
}

/// A chat model on Amazon Bedrock. Credentials come from the environment or an AWS CLI profile, never from settings.
public struct BedrockConfig: Sendable, Equatable, Codable {
    public static let defaultModel = "global.anthropic.claude-haiku-4-5-20251001-v1:0"

    /// A model or inference profile id or ARN.
    public var model: String
    /// Empty for AWS_REGION, then the profile's region.
    public var region: String
    /// An AWS CLI profile; empty for the AWS_* environment variables, then AWS_PROFILE or `default`.
    public var profile: String

    public init(model: String = defaultModel, region: String = "", profile: String = "") {
        self.model = model
        self.region = region
        self.profile = profile
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? ""
        profile = try container.decodeIfPresent(String.self, forKey: .profile) ?? ""
    }
}

/// A chat model on Google Cloud's Gemini Enterprise Agent Platform (formerly Vertex AI), signed in with
/// Application Default Credentials.
public struct GoogleCloudConfig: Sendable, Equatable, Codable {
    public static let defaultModel = "google/gemini-3.5-flash"
    public static let defaultLocation = "global"

    /// A publisher and model, like `google/gemini-3.5-flash`.
    public var model: String
    /// Empty for GOOGLE_CLOUD_PROJECT, then gcloud's project.
    public var project: String
    /// `global` or a region like `us-central1`; empty for `global`.
    public var location: String

    public init(model: String = defaultModel, project: String = "", location: String = "") {
        self.model = model
        self.project = project
        self.location = location
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        project = try container.decodeIfPresent(String.self, forKey: .project) ?? ""
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
    }
}

/// The Built-in model id of Apple's on-device model, for either role.
public let appleModelId = "apple"

public enum ModelSelection: Sendable, Equatable, Codable {
    /// `modelId` is `appleModelId` for Apple's on-device model, otherwise a downloaded model's id.
    case builtIn(modelId: String)
    case endpoint(EndpointConfig)
    /// Chat only.
    case bedrock(BedrockConfig)
    /// Chat only.
    case googleCloud(GoogleCloudConfig)

    public static let apple = ModelSelection.builtIn(modelId: appleModelId)

    public var isApple: Bool { self == .apple }

    public var endpoint: EndpointConfig? {
        if case let .endpoint(config) = self { return config }
        return nil
    }

    public var bedrock: BedrockConfig? {
        if case let .bedrock(config) = self { return config }
        return nil
    }

    public var googleCloud: GoogleCloudConfig? {
        if case let .googleCloud(config) = self { return config }
        return nil
    }

    public var builtInModelId: String? {
        if case let .builtIn(id) = self { return id }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind, modelId, baseUrl, model, apiKey, region, profile, project, location }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "builtIn":
            self = .builtIn(modelId: try container.decode(String.self, forKey: .modelId))
        case "endpoint":
            self = .endpoint(try EndpointConfig(from: decoder))
        case "bedrock":
            self = .bedrock(try BedrockConfig(from: decoder))
        case "googleCloud":
            self = .googleCloud(try GoogleCloudConfig(from: decoder))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .builtIn(id):
            try container.encode("builtIn", forKey: .kind)
            try container.encode(id, forKey: .modelId)
        case let .endpoint(config):
            try container.encode("endpoint", forKey: .kind)
            try container.encode(config.baseUrl, forKey: .baseUrl)
            try container.encode(config.model, forKey: .model)
            try container.encode(config.apiKey, forKey: .apiKey)
        case let .bedrock(config):
            try container.encode("bedrock", forKey: .kind)
            try container.encode(config.model, forKey: .model)
            try container.encode(config.region, forKey: .region)
            try container.encode(config.profile, forKey: .profile)
        case let .googleCloud(config):
            try container.encode("googleCloud", forKey: .kind)
            try container.encode(config.model, forKey: .model)
            try container.encode(config.project, forKey: .project)
            try container.encode(config.location, forKey: .location)
        }
    }
}

/// A change to a role's selection. Fields left nil keep their current value; switching to Bedrock or
/// Google Cloud starts from their defaults.
public enum ModelSelectionPatch: Sendable, Equatable {
    case builtIn(modelId: String)
    case endpoint(baseUrl: String? = nil, model: String? = nil, apiKey: String? = nil)
    case bedrock(model: String? = nil, region: String? = nil, profile: String? = nil)
    case googleCloud(model: String? = nil, project: String? = nil, location: String? = nil)
}

public struct DictionaryEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    /// Spelling the transcript should use.
    public var word: String
    /// Optional: what the speech recognizer tends to produce instead; replaced verbatim with `word`.
    public var replaces: String?

    public init(id: String = UUID().uuidString, word: String, replaces: String? = nil) {
        self.id = id
        self.word = word
        self.replaces = replaces
    }
}

public struct Snippet: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var trigger: String
    public var expansion: String

    public init(id: String = UUID().uuidString, trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

public enum DictationMode: String, Sendable, Codable {
    case ptt, handsFree
}

public enum HistoryStatus: String, Sendable, Codable {
    case pasted, copied, empty, error, cancelled
}

public struct HistoryEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    /// Epoch milliseconds.
    public var timestamp: Double
    public var mode: DictationMode
    public var status: HistoryStatus
    public var asrText: String
    public var formattedText: String
    public var appName: String
    public var bundleId: String
    public var durationMs: Double
    public var numWords: Int
    public var error: String?

    public init(
        id: String = UUID().uuidString, timestamp: Double, mode: DictationMode, status: HistoryStatus, asrText: String,
        formattedText: String, appName: String, bundleId: String, durationMs: Double, numWords: Int, error: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.status = status
        self.asrText = asrText
        self.formattedText = formattedText
        self.appName = appName
        self.bundleId = bundleId
        self.durationMs = durationMs
        self.numWords = numWords
        self.error = error
    }
}

public enum NoticeTone: String, Sendable {
    case info, error
}

public enum FlowBarState: Sendable, Equatable {
    case hidden
    case resting
    case initializing(DictationMode)
    case listening(DictationMode)
    case processing
    case notice(String, NoticeTone)

    /// Whether the bar shows something beyond its resting pill.
    public var isActive: Bool {
        switch self {
        case .hidden, .resting: false
        case .initializing, .listening, .processing, .notice: true
        }
    }
}

public enum MicrophonePermission: String, Sendable {
    case granted, denied, notDetermined, restricted, unknown
}

public struct PermissionStatus: Sendable, Equatable {
    public var accessibility: Bool
    public var keyTapRunning: Bool
    public var microphone: MicrophonePermission

    public init(accessibility: Bool, keyTapRunning: Bool, microphone: MicrophonePermission) {
        self.accessibility = accessibility
        self.keyTapRunning = keyTapRunning
        self.microphone = microphone
    }
}

public struct Stats: Sendable, Equatable {
    public var totalWords: Int
    public var totalDictations: Int
    public var averageWpm: Int
}

/// `mic` is the user; `system` is everything the Mac plays, i.e. the other meeting participants.
public enum TranscriptSource: String, Sendable, Codable, CaseIterable {
    case mic, system
}

public struct TranscriptEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var source: TranscriptSource
    public var text: String
    /// Offsets into the meeting's total recorded time, so resumed recordings continue the timeline.
    public var startMs: Double
    public var endMs: Double
    /// Who spoke on the call audio, as a speaker key (see `Speakers`); nil when unknown.
    public var speaker: String?

    public init(id: String = UUID().uuidString, source: TranscriptSource, text: String, startMs: Double, endMs: Double, speaker: String? = nil) {
        self.id = id
        self.source = source
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
    }
}

public enum MeetingPlatform: String, Sendable, Codable {
    case zoom, teams, meet, slack

    public var label: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .meet: "Google Meet"
        case .slack: "Slack huddle"
        }
    }
}

/// Who the meeting app shows as talking right now.
public struct LiveSpeakers: Sendable, Equatable {
    public var platform: MeetingPlatform?
    public var speaking: [String]

    public init(platform: MeetingPlatform? = nil, speaking: [String] = []) {
        self.platform = platform
        self.speaking = speaking
    }
}

public struct Meeting: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var createdAt: Double
    public var modifiedAt: Double
    /// The user's own notes, plain text. The AI summary is kept separately and never merged in.
    public var notes: String
    /// Markdown, or nil until one has been generated.
    public var summary: String?
    /// `recordedMs` when the summary was generated; less than `recordedMs` means new audio since.
    public var summaryRecordedMs: Double
    public var summaryError: String?
    public var recordedMs: Double
    public var transcriptWords: Int
    /// Names the user gave speakers, by speaker key; they override the detected labels everywhere.
    public var speakerNames: [String: String]
    /// Runtime only; never persisted.
    public var summaryGenerating = false

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, modifiedAt, notes, summary, summaryRecordedMs, summaryError, recordedMs, transcriptWords, speakerNames
    }

    public init(id: String = UUID().uuidString, createdAt: Double) {
        self.id = id
        title = ""
        self.createdAt = createdAt
        modifiedAt = createdAt
        notes = ""
        summary = nil
        summaryRecordedMs = 0
        summaryError = nil
        recordedMs = 0
        transcriptWords = 0
        speakerNames = [:]
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        modifiedAt = try container.decodeIfPresent(Double.self, forKey: .modifiedAt) ?? createdAt
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        summaryRecordedMs = try container.decodeIfPresent(Double.self, forKey: .summaryRecordedMs) ?? 0
        summaryError = try container.decodeIfPresent(String.self, forKey: .summaryError)
        recordedMs = try container.decodeIfPresent(Double.self, forKey: .recordedMs) ?? 0
        transcriptWords = try container.decodeIfPresent(Int.self, forKey: .transcriptWords) ?? 0
        // Meetings saved before speaker naming existed have no `speakerNames`.
        speakerNames = try container.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(notes, forKey: .notes)
        try container.encode(summary, forKey: .summary)
        try container.encode(summaryRecordedMs, forKey: .summaryRecordedMs)
        try container.encode(summaryError, forKey: .summaryError)
        try container.encode(recordedMs, forKey: .recordedMs)
        try container.encode(transcriptWords, forKey: .transcriptWords)
        try container.encode(speakerNames, forKey: .speakerNames)
    }
}

public struct MeetingDetail: Sendable, Equatable {
    public var meeting: Meeting
    public var transcript: [TranscriptEntry]
}

public enum SystemAudioStatus: Sendable, Equatable {
    case starting
    case capturing
    case unavailable(String)
}

public enum NotetakerState: Sendable, Equatable {
    case idle(error: String? = nil)
    case recording(Recording)
    case finishing(meetingId: String)

    public struct Recording: Sendable, Equatable {
        public var meetingId: String
        /// Epoch ms.
        public var startedAt: Double
        public var baseRecordedMs: Double
        public var systemAudio: SystemAudioStatus
        public var speakers: LiveSpeakers
        /// Latest chunk transcription failure; cleared by the next success.
        public var error: String?
    }

    public var meetingId: String? {
        switch self {
        case .idle: nil
        case let .recording(recording): recording.meetingId
        case let .finishing(id): id
        }
    }

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// What the engines report about Apple's models on this Mac.
public struct BuiltInStatus: Sendable, Equatable {
    public struct AppleSpeech: Sendable, Equatable {
        public var available: Bool
        /// Why Apple's speech-to-text can't be used, when it can't.
        public var reason: String?
        /// The locale the language setting maps to, or nil when Apple doesn't support that language.
        public var locale: String?
        /// BCP 47 locales Apple's speech-to-text supports on this Mac.
        public var locales: [String]

        public init(available: Bool, reason: String? = nil, locale: String? = nil, locales: [String] = []) {
            self.available = available
            self.reason = reason
            self.locale = locale
            self.locales = locales
        }
    }

    public enum AppleChatFix: String, Sendable {
        case turnOnAppleIntelligence, wait
    }

    public struct AppleChat: Sendable, Equatable {
        public var available: Bool
        public var reason: String?
        public var fix: AppleChatFix?
        /// Tokens the model reads and writes per request; nil when unavailable.
        public var contextSize: Int?

        public init(available: Bool, reason: String? = nil, fix: AppleChatFix? = nil, contextSize: Int? = nil) {
            self.available = available
            self.reason = reason
            self.fix = fix
            self.contextSize = contextSize
        }
    }

    public struct DownloadedSpeech: Sendable, Equatable {
        public var model: String
        public var name: String
        /// Whether it transcribes the language setting; an empty setting means it auto-detects.
        public var supported: Bool
        /// ISO language codes, or nil when it isn't limited to a known set.
        public var languages: [String]?

        public init(model: String, name: String, supported: Bool, languages: [String]?) {
            self.model = model
            self.name = name
            self.supported = supported
            self.languages = languages
        }
    }

    public struct DownloadedChat: Sendable, Equatable {
        public var model: String
        public var name: String
        /// Tokens a request and its answer may use together, capped to what fits in memory.
        public var contextSize: Int

        public init(model: String, name: String, contextSize: Int) {
            self.model = model
            self.name = name
            self.contextSize = contextSize
        }
    }

    public var appleSpeech: AppleSpeech
    public var appleChat: AppleChat
    public var speechToText: DownloadedSpeech?
    public var chat: DownloadedChat?

    public init(appleSpeech: AppleSpeech, appleChat: AppleChat, speechToText: DownloadedSpeech? = nil, chat: DownloadedChat? = nil) {
        self.appleSpeech = appleSpeech
        self.appleChat = appleChat
        self.speechToText = speechToText
        self.chat = chat
    }
}

/// An Apple language-asset download, or a downloaded model's slow first load, which compiles it for this Mac.
public enum ModelProgress: Sendable, Equatable {
    case appleSpeechAssets(locale: String, fraction: Double)
    case preparingModel(modelId: String, name: String, preparing: Bool)

    public var isOngoing: Bool {
        switch self {
        case let .appleSpeechAssets(_, fraction): fraction < 1
        case let .preparingModel(_, _, preparing): preparing
        }
    }

    public var label: String {
        switch self {
        case let .appleSpeechAssets(locale, fraction):
            "Downloading Apple’s speech-to-text for \(locale)… \(Int((fraction * 100).rounded()))%"
        case let .preparingModel(_, name, _):
            "Preparing \(name) for this Mac… The first use can take a couple of minutes."
        }
    }
}

public struct ChatMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable {
        case system, user
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage { ChatMessage(role: .system, content: content) }
    public static func user(_ content: String) -> ChatMessage { ChatMessage(role: .user, content: content) }
}

/// A transcribed stretch of audio. Times are milliseconds from the start of the audio.
public struct TranscriptSegment: Sendable, Equatable {
    public var startMs: Double
    public var endMs: Double
    public var text: String
    /// The diarization label, when the model tells voices apart.
    public var speaker: String?

    public init(startMs: Double, endMs: Double, text: String, speaker: String? = nil) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speaker = speaker
    }
}

/// What a model engine reports went wrong; the code decides how Dictation and the Notetaker react.
public enum ModelError: Error, Sendable, Equatable, LocalizedError {
    case unavailable(String)
    case unsupportedLanguage(String)
    case contextExceeded(String)
    case refused(String)
    case modelFailed(String)

    public var message: String {
        switch self {
        case let .unavailable(message), let .unsupportedLanguage(message), let .contextExceeded(message),
             let .refused(message), let .modelFailed(message):
            message
        }
    }

    public var errorDescription: String? { message }
}

/// A plain error carrying a user-facing message.
public struct AppError: Error, Sendable, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public func errorMessage(_ error: any Error) -> String {
    if let error = error as? LocalizedError, let description = error.errorDescription { return description }
    return error.localizedDescription
}
