import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import OpenWisprCore

struct FakeFile: Sendable {
    var content: Data
    var lfs = false
}

func text(_ s: String, lfs: Bool = false) -> FakeFile { FakeFile(content: Data(s.utf8), lfs: lfs) }

/// Files in listing order.
typealias FakeRepo = [(path: String, file: FakeFile)]

struct FakeRepoInfo: Sendable {
    var gated: String?
    var languages: [String]?
}

struct FakeRequest: Sendable {
    var url: String
    var range: String?
    var body: Data?
    var authorization: String?

    /// The values of a multipart form field.
    func form(_ name: String) -> [String] {
        let body = String(decoding: body ?? Data(), as: UTF8.self)
        let pattern = "name=\"\(NSRegularExpression.escapedPattern(for: name))\"\r\n\r\n([^\r]*)\r\n"
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { String(body[Range($0.range(at: 1), in: body)!]) }
    }

    var json: [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
}

struct FakeResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    /// Thrown after the chunks, like a dropped connection.
    var failure: (any Error)?
    /// Keeps sending this chunk forever after `chunks`.
    var endless: Data?
    /// Sends nothing more after `chunks`, until cancelled.
    var hangs = false

    static func body(_ data: Data, status: Int = 200, headers: [String: String] = [:]) -> FakeResponse {
        FakeResponse(status: status, headers: headers, chunks: [data])
    }

    static func json(_ value: String, status: Int = 200, headers: [String: String] = [:]) -> FakeResponse {
        body(Data(value.utf8), status: status, headers: headers)
    }
}

struct Dropped: Error, LocalizedError {
    var message = "terminated"
    var errorDescription: String? { message }
}

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).hex }

func gitBlobSha1(_ data: Data) -> String {
    var hash = Insecure.SHA1()
    hash.update(data: Data("blob \(data.count)\0".utf8))
    hash.update(data: data)
    return hash.finalize().hex
}

private func jsonText(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes, .sortedKeys]), as: UTF8.self)
}

/// A test double for the network. It serves the Hugging Face Hub: the info call (`/api/models/<repo>`, its
/// first listed sha being the head of `main`, and `/revision/<rev>`), tree listings (two entries per page,
/// linked with `Link: rel="next"`) and `resolve` downloads honouring `Range`. Unknown repos answer 401, as
/// private and missing repos do anonymously. `override` can answer any request instead, to script failures
/// or other servers.
final class FakeHub: HTTPClient {
    let repos: [String: FakeRepo]
    let info: [String: FakeRepoInfo]
    let override: (@Sendable (String, FakeRequest) throws -> FakeResponse?)?
    private let log = Mutex<[FakeRequest]>([])

    init(_ repos: [String: FakeRepo] = [:], info: [String: FakeRepoInfo] = [:], override: (@Sendable (String, FakeRequest) throws -> FakeResponse?)? = nil) {
        self.repos = repos
        self.info = info
        self.override = override
    }

    var requests: [FakeRequest] { log.withLock { $0 } }

    var downloadedPaths: [String] {
        requests.filter { $0.url.contains("/resolve/") }.map { URL(string: $0.url)!.path.split(separator: "/").dropFirst(4).joined(separator: "/") }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (response, body) = try await stream(for: request)
        var data = Data()
        for try await chunk in body { data.append(chunk) }
        return (data, response)
    }

    func stream(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let url = request.url!
        let fake = FakeRequest(
            url: url.absoluteString, range: request.value(forHTTPHeaderField: "Range"), body: request.httpBody,
            authorization: request.value(forHTTPHeaderField: "Authorization")
        )
        log.withLock { $0.append(fake) }
        try Task.checkCancellation()
        let answer = try respond(url, fake)
        let http = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                for chunk in answer.chunks { continuation.yield(chunk) }
                if let endless = answer.endless {
                    while !Task.isCancelled {
                        continuation.yield(endless)
                        await Task.yield()
                    }
                }
                if answer.hangs {
                    try? await Task.sleep(for: .seconds(3600))
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.finish(throwing: answer.failure)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, body)
    }

    private func revisions(_ repo: String) -> [String] {
        repos.keys.filter { $0.hasPrefix("\(repo)@") }.map { String($0.dropFirst(repo.count + 1)) }.sorted()
    }

    private func unauthorized() -> FakeResponse { .json(#"{"error":"Invalid username or password."}"#, status: 401) }

    private func respond(_ url: URL, _ request: FakeRequest) throws -> FakeResponse {
        let path = url.path(percentEncoded: true)
        if let overridden = try override?(path.removingPercentEncoding ?? path, request) { return overridden }

        if let about = path.firstMatch(#"^/api/models/([^/]+/[^/]+)(?:/revision/([^/]+))?/?$"#), let repo = about[1] {
            let known = revisions(repo)
            if known.isEmpty { return unauthorized() }
            let revision = about[2]
            guard let sha = revision == nil || revision == "main" ? known.first : known.first(where: { $0 == revision }) else {
                return .json(#"{"error":"Invalid rev id"}"#, status: 404, headers: ["x-error-code": "RevisionNotFound"])
            }
            var body: [String: Any] = ["id": repo, "sha": sha, "private": false]
            if let gated = info[repo]?.gated { body["gated"] = gated } else { body["gated"] = false }
            if let languages = info[repo]?.languages { body["cardData"] = ["language": languages] }
            return .json(jsonText(body))
        }

        if let tree = path.firstMatch(#"^/api/models/([^/]+/[^/]+)/tree/([^/]+)/?(.*)$"#), let repo = tree[1], let revision = tree[2] {
            guard let files = repos["\(repo)@\(revision)"] else { return unauthorized() }
            let folder = (tree[3] ?? "").removingPercentEncoding ?? ""
            let entries: [[String: Any]] = files.filter { folder.isEmpty || $0.path.hasPrefix("\(folder)/") }.flatMap { path, file -> [[String: Any]] in
                var listed: [[String: Any]] = []
                if let slash = path.lastIndex(of: "/") {
                    listed.append(["type": "directory", "oid": "d", "size": 0, "path": String(path[..<slash])])
                }
                var entry: [String: Any] = ["type": "file", "oid": gitBlobSha1(file.content), "size": file.content.count, "path": path]
                if file.lfs { entry["lfs"] = ["oid": sha256Hex(file.content), "size": file.content.count, "pointerSize": 135] }
                listed.append(entry)
                return listed
            }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let cursor = Int(components.queryItems?.first { $0.name == "cursor" }?.value ?? "0") ?? 0
            var next = components
            next.queryItems = (components.queryItems ?? []).filter { $0.name != "cursor" } + [URLQueryItem(name: "cursor", value: String(cursor + 2))]
            let page = Array(entries[min(cursor, entries.count)..<min(cursor + 2, entries.count)])
            return .json(jsonText(page), headers: cursor + 2 < entries.count ? ["Link": "<\(next.url!.absoluteString)>; rel=\"next\""] : [:])
        }

        if let resolve = path.firstMatch(#"^/([^/]+/[^/]+)/resolve/([^/]+)/(.+)$"#), let repo = resolve[1], let revision = resolve[2], let encoded = resolve[3] {
            let filePath = encoded.removingPercentEncoding ?? encoded
            if info[repo]?.gated != nil {
                return .json("Access restricted", status: 401, headers: ["x-error-code": "GatedRepo"])
            }
            guard let file = repos["\(repo)@\(revision)"]?.first(where: { $0.path == filePath })?.file else {
                return .json("Entry not found", status: 404, headers: ["x-error-code": "EntryNotFound"])
            }
            guard let range = request.range else { return .body(file.content) }
            let from = Int(range.firstMatch(#"^bytes=(\d+)-$"#)?[1] ?? "0") ?? 0
            if from >= file.content.count { return FakeResponse(status: 416) }
            return .body(
                file.content.subdata(in: from..<file.content.count), status: 206,
                headers: ["Content-Range": "bytes \(from)-\(file.content.count - 1)/\(file.content.count)"]
            )
        }
        return .json("not found", status: 404)
    }
}

/// Built-in engines that answer at once, recording every call.
final class FakeEngines: BuiltInEngines {
    enum Call: Equatable, Sendable {
        case transcribe(model: String, language: String, prompt: String, segments: Bool)
        case complete(model: String, maxTokens: Int)
        case load([ModelRef])
        case unload([String])
        case status(language: String, speechToText: String?, chat: String?)
        case stop
    }

    struct Script: Sendable {
        var transcription = EngineTranscription(text: "hello world")
        var completion = "OK"
        var transcribeError: ModelError?
        var completeError: ModelError?
        var status = BuiltInStatus(
            appleSpeech: .init(available: true, locale: "en-US", locales: ["en-US"]),
            appleChat: .init(available: true, contextSize: 4096)
        )
        var loadDelay: Duration?
        /// Loads wait for it to open.
        var loadGate: Gate?
        var completeDelay: Duration?
        var completeHandler: (@Sendable ([ChatMessage], Int) throws -> String)?
    }

    private let state: Mutex<(calls: [Call], script: Script, lastMessages: [ChatMessage])>

    init(_ script: Script = Script()) {
        state = Mutex((calls: [], script: script, lastMessages: []))
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var lastMessages: [ChatMessage] { state.withLock { $0.lastMessages } }

    func update(_ change: (inout Script) -> Void) { state.withLock { change(&$0.script) } }

    private func record(_ call: Call) -> Script {
        state.withLock {
            $0.calls.append(call)
            return $0.script
        }
    }

    func transcribe(model: String, wav: Data, language: String, prompt: String, segments: Bool) async throws -> EngineTranscription {
        let script = record(.transcribe(model: model, language: language, prompt: prompt, segments: segments))
        if let error = script.transcribeError { throw error }
        return script.transcription
    }

    func complete(model: String, messages: [ChatMessage], maxTokens: Int) async throws -> String {
        let script = record(.complete(model: model, maxTokens: maxTokens))
        state.withLock { $0.lastMessages = messages }
        if let delay = script.completeDelay { try await Task.sleep(for: delay) }
        if let error = script.completeError { throw error }
        if let handler = script.completeHandler { return try handler(messages, maxTokens) }
        return script.completion
    }

    func load(_ models: [ModelRef]) async throws {
        let script = record(.load(models))
        if let delay = script.loadDelay { try await Task.sleep(for: delay) }
        await script.loadGate?.wait()
    }

    func unload(_ models: [String]) async throws { _ = record(.unload(models)) }

    func status(language: String, speechToText: String?, chat: String?) async throws -> BuiltInStatus {
        record(.status(language: language, speechToText: speechToText, chat: chat)).status
    }

    func stop() async { _ = record(.stop) }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "openwispr-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Settings held by the test, read by `Models` on each call like the app's store.
@MainActor
final class SettingsBox {
    var settings: Settings
    init(_ settings: Settings = Settings()) { self.settings = settings }
}

@MainActor
func makeModels(
    _ http: any HTTPClient = FakeHub(), engines: FakeEngines = FakeEngines(), settings: SettingsBox = SettingsBox(),
    directory: URL, physicalMemoryBytes: Int64 = 32_000_000_000
) async -> Models {
    let models = Models(
        settings: { settings.settings }, engines: engines, http: http, modelsDirectory: directory,
        physicalMemoryBytes: physicalMemoryBytes, retryDelay: .zero
    )
    await models.refresh()
    return models
}

@MainActor
func status(_ models: Models, _ id: String) async throws -> ModelStatus {
    await models.refreshLibrary()
    return try #require(models.library.models.first { $0.model.id == id })
}

/// Returns whether it was already set, setting it.
final class LockedFlag: Sendable {
    private let flag = Mutex(false)
    func set() -> Bool { flag.withLock { defer { $0 = true }; return $0 } }
}

/// Holds its waiters until opened.
actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { waiters.count }

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Polls `condition` until it holds, failing after `timeout`.
func eventually(
    timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () async throws -> Bool
) async rethrows {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition never held", sourceLocation: sourceLocation)
}

/// Returns 0, 1, 2… on successive calls.
final class LockedCounter: Sendable {
    private let count = Mutex(0)
    func next() -> Int { count.withLock { defer { $0 += 1 }; return $0 } }
}
