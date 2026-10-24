import Foundation
import Observation

/// Where API keys live; the app uses the Keychain.
@MainActor
public protocol SecretStore: AnyObject {
    func secret(_ account: String) -> String?
    func setSecret(_ account: String, _ value: String?)
}

@MainActor
public final class InMemorySecretStore: SecretStore {
    public private(set) var secrets: [String: String]
    public init(_ secrets: [String: String] = [:]) { self.secrets = secrets }
    public func secret(_ account: String) -> String? { secrets[account] }
    public func setSecret(_ account: String, _ value: String?) { secrets[account] = value?.isEmpty == false ? value : nil }
}

let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    return encoder
}()

func readJson<T: Decodable>(_ url: URL, as type: T.Type) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

func writeJsonAtomic(_ url: URL, _ value: some Encodable) {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonEncoder.encode(value).write(to: url, options: .atomic)
    } catch {
        print("openwispr: could not write \(url.lastPathComponent): \(error)")
    }
}

/// Decodes each element on its own, dropping the ones that don't parse.
struct LenientArray<Element: Decodable>: Decodable {
    var elements: [Element]

    private struct Skip: Decodable {}

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        self.elements = elements
    }
}

/// Runs `action` once, `delay` after the last `schedule` call.
@MainActor
final class Debouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration) { self.delay = delay }

    var isPending: Bool { task != nil }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.task = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

public func epochMs() -> Double { Date().timeIntervalSince1970 * 1000 }

/// Settings, the Dictionary and Snippets in `openwispr.json`; dictation History in `history.json`.
/// API keys are kept in the `SecretStore`; the settings file stores them empty.
@Observable
@MainActor
public final class DataStore {
    public static let historyLimit = 2000

    private struct StoredData: Codable {
        var settings: Settings
        var dictionary: [DictionaryEntry]
        var snippets: [Snippet]

        init(settings: Settings, dictionary: [DictionaryEntry], snippets: [Snippet]) {
            self.settings = settings
            self.dictionary = dictionary
            self.snippets = snippets
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            settings = (try? container.decodeIfPresent(Settings.self, forKey: .settings)) ?? Settings()
            dictionary = (try? container.decodeIfPresent(LenientArray<DictionaryEntry>.self, forKey: .dictionary))?.elements ?? []
            snippets = (try? container.decodeIfPresent(LenientArray<Snippet>.self, forKey: .snippets))?.elements ?? []
        }
    }

    /// Settings with API keys filled in from the secret store.
    public private(set) var settings: Settings
    public private(set) var dictionary: [DictionaryEntry]
    public private(set) var snippets: [Snippet]
    public private(set) var history: [HistoryEntry]

    @ObservationIgnored private let dataURL: URL
    @ObservationIgnored private let historyURL: URL
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let historyWrite = Debouncer(delay: .milliseconds(250))

    public init(directory: URL, secrets: SecretStore) {
        dataURL = directory.appending(path: "openwispr.json")
        historyURL = directory.appending(path: "history.json")
        self.secrets = secrets
        let stored = readJson(dataURL, as: StoredData.self) ?? StoredData(settings: Settings(), dictionary: [], snippets: [])
        var settings = stored.settings
        var migratedKeys = false
        for role in ModelRole.allCases {
            guard case var .endpoint(config) = settings[role] else { continue }
            if config.apiKey.hasPrefix("enc:") {
                // Encrypted by the Electron app's safeStorage, which this app can't read.
                config.apiKey = ""
                migratedKeys = true
            } else if !config.apiKey.isEmpty {
                secrets.setSecret(role.rawValue, config.apiKey)
                migratedKeys = true
            }
            config.apiKey = secrets.secret(role.rawValue) ?? ""
            settings[role] = .endpoint(config)
        }
        self.settings = settings
        dictionary = stored.dictionary
        snippets = stored.snippets
        history = (readJson(historyURL, as: LenientArray<HistoryEntry>.self))?.elements ?? []
        if migratedKeys { save() }
    }

    public func updateSettings(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        save()
    }

    public func updateSelection(_ role: ModelRole, _ patch: ModelSelectionPatch) {
        updateSettings { $0[role] = $0[role].applying(patch) }
    }

    public func setDictionary(_ entries: [DictionaryEntry]) {
        dictionary = entries.filter { !$0.word.trimmed.isEmpty }
        save()
    }

    public func setSnippets(_ entries: [Snippet]) {
        snippets = entries.filter { !$0.trigger.trimmed.isEmpty }
        save()
    }

    @discardableResult
    public func addHistory(_ entry: HistoryEntry) -> HistoryEntry {
        history = Array(([entry] + history).prefix(Self.historyLimit))
        saveHistory()
        return entry
    }

    public func deleteHistory(_ id: String) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    public func clearHistory() {
        history = []
        saveHistory()
    }

    /// Most recent text that was actually produced, for paste-last and copy-last.
    public func lastText() -> String? {
        history.first { !$0.formattedText.isEmpty }?.formattedText
    }

    public var stats: Stats {
        let done = history.filter { $0.status == .pasted || $0.status == .copied }
        let totalWords = done.reduce(0) { $0 + $1.numWords }
        let minutes = done.reduce(0) { $0 + $1.durationMs } / 60000
        return Stats(
            totalWords: totalWords,
            totalDictations: done.count,
            averageWpm: minutes > 0 ? Int((Double(totalWords) / minutes).rounded()) : 0
        )
    }

    public func flush() {
        guard historyWrite.isPending else { return }
        historyWrite.cancel()
        writeJsonAtomic(historyURL, history)
    }

    private func save() {
        var stored = settings
        for role in ModelRole.allCases {
            guard case var .endpoint(config) = stored[role] else { continue }
            secrets.setSecret(role.rawValue, config.apiKey)
            config.apiKey = ""
            stored[role] = .endpoint(config)
        }
        writeJsonAtomic(dataURL, StoredData(settings: stored, dictionary: dictionary, snippets: snippets))
    }

    private func saveHistory() {
        historyWrite.schedule { [weak self] in
            guard let self else { return }
            writeJsonAtomic(historyURL, history)
        }
    }
}
