import Foundation

/// The app's color scheme; `system` follows macOS.
public enum Appearance: String, CaseIterable, Sendable, Codable {
    case system, light, dark

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public struct Settings: Sendable, Equatable, Codable {
    public struct Cleanup: Sendable, Equatable, Codable {
        public var enabled: Bool
        public init(enabled: Bool) { self.enabled = enabled }
    }

    public var speechToText: ModelSelection = .apple
    public var chat: ModelSelection = .apple
    /// ISO code like `en`; empty to auto-detect.
    public var language = ""
    public var cleanup = Cleanup(enabled: true)
    public var shortcuts: Shortcuts = .defaults
    public var styles: Styles = .defaults
    /// A Core Audio device UID; empty for the system default.
    public var microphoneId = ""
    public var sounds = true
    public var restoreClipboard = true
    public var showFlowBar = true
    public var launchAtLogin = false
    public var userName = ""
    public var appearance: Appearance = .system

    public init() {}

    public subscript(role: ModelRole) -> ModelSelection {
        get { role == .chat ? chat : speechToText }
        set {
            if role == .chat { chat = newValue } else { speechToText = newValue }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case speechToText, chat, language, cleanup, shortcuts, styles, microphoneId, sounds, restoreClipboard, showFlowBar, launchAtLogin, userName, appearance
        /// Before Models, each role was an Endpoint config, with Cleanup's living under `cleanup`.
        case transcription
    }

    private struct LegacyEndpoint: Decodable {
        var baseUrl: String?
        var model: String?
        var apiKey: String?
        var language: String?
        var enabled: Bool?
    }

    /// What older versions used when a field was missing.
    private static let legacyBaseUrl = "https://api.openai.com/v1"

    /// Reads settings leniently: missing or malformed fields keep their defaults. An older role stays on its
    /// Endpoint when the user changed its base URL or stored a key; otherwise it moves to Apple's model. Chat
    /// without a key of its own gets a copy of the transcription key for the same server, which older versions lent it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }
        let speechToTextSelection = value(ModelSelection.self, .speechToText)
        let chatSelection = value(ModelSelection.self, .chat)
        language = value(String.self, .language) ?? ""
        shortcuts = value(Shortcuts.self, .shortcuts) ?? .defaults
        styles = value(Styles.self, .styles) ?? .defaults
        microphoneId = value(String.self, .microphoneId) ?? ""
        sounds = value(Bool.self, .sounds) ?? true
        restoreClipboard = value(Bool.self, .restoreClipboard) ?? true
        showFlowBar = value(Bool.self, .showFlowBar) ?? true
        launchAtLogin = value(Bool.self, .launchAtLogin) ?? false
        userName = value(String.self, .userName) ?? ""
        appearance = value(Appearance.self, .appearance) ?? .system

        let isCustom = { (config: EndpointConfig) in config.baseUrl != Self.legacyBaseUrl || !config.apiKey.isEmpty }
        var legacySpeech: EndpointConfig?
        if let transcription = value(LegacyEndpoint.self, .transcription) {
            let config = EndpointConfig(
                baseUrl: transcription.baseUrl ?? Self.legacyBaseUrl,
                model: transcription.model ?? "gpt-4o-mini-transcribe",
                apiKey: transcription.apiKey ?? ""
            )
            legacySpeech = config
            if speechToTextSelection == nil, isCustom(config) { speechToText = .endpoint(config) }
            if value(String.self, .language) == nil { language = transcription.language ?? "" }
        }
        speechToText = speechToTextSelection ?? speechToText

        if let legacyCleanup = value(LegacyEndpoint.self, .cleanup) {
            var config = EndpointConfig(
                baseUrl: legacyCleanup.baseUrl ?? Self.legacyBaseUrl,
                model: legacyCleanup.model ?? "gpt-4.1-mini",
                apiKey: legacyCleanup.apiKey ?? ""
            )
            if config.apiKey.isEmpty, let legacySpeech, legacySpeech.baseUrl == config.baseUrl { config.apiKey = legacySpeech.apiKey }
            if chatSelection == nil, isCustom(config) { chat = .endpoint(config) }
            cleanup = Cleanup(enabled: legacyCleanup.enabled ?? true)
        }
        chat = chatSelection ?? chat
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(speechToText, forKey: .speechToText)
        try container.encode(chat, forKey: .chat)
        try container.encode(language, forKey: .language)
        try container.encode(cleanup, forKey: .cleanup)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(styles, forKey: .styles)
        try container.encode(microphoneId, forKey: .microphoneId)
        try container.encode(sounds, forKey: .sounds)
        try container.encode(restoreClipboard, forKey: .restoreClipboard)
        try container.encode(showFlowBar, forKey: .showFlowBar)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(userName, forKey: .userName)
        try container.encode(appearance, forKey: .appearance)
    }
}

extension ModelSelection {
    /// The selection after `patch`. An API key is a credential for one server, so changing the base URL to
    /// another origin drops the stored key unless the patch brings a new one.
    public func applying(_ patch: ModelSelectionPatch) -> ModelSelection {
        switch patch {
        case let .builtIn(modelId):
            return .builtIn(modelId: modelId)
        case let .endpoint(baseUrl, model, apiKey):
            let base = endpoint ?? EndpointConfig(baseUrl: "", model: "", apiKey: "")
            let newBaseUrl = baseUrl ?? base.baseUrl
            let keptKey = sameOrigin(newBaseUrl, base.baseUrl) ? base.apiKey : ""
            return .endpoint(EndpointConfig(baseUrl: newBaseUrl, model: model ?? base.model, apiKey: apiKey ?? keptKey))
        case let .bedrock(model, region, profile):
            let base = bedrock ?? BedrockConfig()
            return .bedrock(BedrockConfig(model: model ?? base.model, region: region ?? base.region, profile: profile ?? base.profile))
        case let .googleCloud(model, project, location):
            let base = googleCloud ?? GoogleCloudConfig()
            return .googleCloud(GoogleCloudConfig(model: model ?? base.model, project: project ?? base.project, location: location ?? base.location))
        }
    }
}

func sameOrigin(_ a: String, _ b: String) -> Bool {
    func origin(_ url: String) -> String {
        let trimmed = url.trimmed
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme, let host = components.host, !host.isEmpty else {
            return trimmed
        }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        let port = components.port.flatMap { $0 == defaultPort ? nil : $0 }
        return "\(scheme.lowercased())://\(host.lowercased())\(port.map { ":\($0)" } ?? "")"
    }
    return origin(a) == origin(b)
}

extension Settings {
    /// The Endpoint serving `role` with its effective API key, or nil when a Built-in model is selected. A chat
    /// Endpoint on the same server as speech-to-text uses that key when it has none of its own.
    public func resolvedEndpoint(_ role: ModelRole) -> EndpointConfig? {
        guard var config = self[role].endpoint else { return nil }
        if config.apiKey.isEmpty, let other = self[role.other].endpoint, other.baseUrl == config.baseUrl {
            config.apiKey = other.apiKey
        }
        return config
    }

    /// The combos the event tap must swallow; Esc only while dictating.
    public func swallowedCombos(dictating: Bool) -> [[Int]] {
        var combos = shortcuts.all.filter { !$0.isEmpty }
        if dictating { combos.append([Key.esc]) }
        return combos
    }
}
