import Foundation

/// The network, injectable so tests answer requests themselves.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// The response head, then the body in chunks as it arrives.
    func stream(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>)
}

public struct URLSessionHTTPClient: HTTPClient {
    private static let chunkBytes = 256 * 1024

    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError("Not an HTTP response") }
        return (data, http)
    }

    public func stream(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError("Not an HTTP response") }
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let reader = Task {
                do {
                    var chunk = Data(capacity: Self.chunkBytes)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count >= Self.chunkBytes {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                bytes.task.cancel()
            }
        }
        return (http, body)
    }
}

/// Who a diarizing model should recognize: `references` are `data:audio/wav;base64,…` clips, one per name.
public struct KnownSpeakers: Sendable, Equatable {
    public var names: [String]
    public var references: [String]

    public init(names: [String], references: [String]) {
        self.names = names
        self.references = references
    }
}

/// OpenAI-compatible endpoints (OpenAI, Groq, whisper.cpp server, LocalAI, Speaches, …).
public struct EndpointClient: Sendable {
    public static let timeout: TimeInterval = 60

    private let http: any HTTPClient

    public init(http: any HTTPClient) { self.http = http }

    /// `/audio/transcriptions`.
    public func transcribe(_ config: EndpointConfig, language: String, wav: Data, prompt: String) async throws -> String {
        var form = MultipartForm()
        form.file("file", filename: "dictation.wav", type: "audio/wav", data: wav)
        form.field("model", config.model)
        form.field("response_format", "json")
        if !language.isEmpty { form.field("language", language) }
        if !prompt.isEmpty { form.field("prompt", prompt) }
        let data = try await send(form.request(url(config, "/audio/transcriptions"), config: config), what: "Transcription")
        let json = try? JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return (json?.text ?? "").trimmed
    }

    /// Like `transcribe`, but keeps the timing and, for diarizing models, the voice of each segment.
    public func transcribeSegments(
        _ config: EndpointConfig, language: String, wav: Data, durationMs: Double, prompt: String, known: KnownSpeakers? = nil
    ) async throws -> [TranscriptSegment] {
        let format = SegmentFormat(model: config.model)
        var form = MultipartForm()
        form.file("file", filename: "meeting.wav", type: "audio/wav", data: wav)
        form.field("model", config.model)
        form.field("response_format", format.rawValue)
        if !language.isEmpty { form.field("language", language) }
        switch format {
        case .diarizedJson:
            form.field("chunking_strategy", "auto")
            for name in known?.names ?? [] { form.field("known_speaker_names[]", name) }
            for reference in known?.references ?? [] { form.field("known_speaker_references[]", reference) }
        case .verboseJson:
            form.field("timestamp_granularities[]", "segment")
            if !prompt.isEmpty { form.field("prompt", prompt) }
        case .json:
            if !prompt.isEmpty { form.field("prompt", prompt) }
        }
        let data = try await send(form.request(url(config, "/audio/transcriptions"), config: config), what: "Transcription")
        let json = (try? JSONDecoder().decode(TranscriptionResponse.self, from: data)) ?? TranscriptionResponse(text: nil, segments: nil)
        return parseSegments(json, durationMs: durationMs)
    }

    /// `/chat/completions`.
    public func complete(_ config: EndpointConfig, messages: [ChatMessage], label: String = "Cleanup", timeout: TimeInterval = timeout) async throws -> String {
        var request = URLRequest(url: try url(config, "/chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        authorize(&request, config)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(model: config.model, messages: messages))
        let data = try await send(request, what: label)
        let json = try? JSONDecoder().decode(ChatResponse.self, from: data)
        return json?.choices?.first?.message?.content ?? ""
    }

    private func url(_ config: EndpointConfig, _ path: String) throws -> URL {
        let base = config.baseUrl.replacing(pattern: "/+$", with: "")
        guard let url = URL(string: base + path), url.scheme != nil else { throw AppError("Invalid base URL: \(config.baseUrl)") }
        return url
    }

    private func send(_ request: URLRequest, what: String) async throws -> Data {
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message ?? String(body.prefix(300))
            throw AppError("\(what) failed (\(response.statusCode)): \(detail)")
        }
        return data
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { var message: String? }
        var error: Detail?
    }

    private struct ChatRequest: Encodable {
        var model: String
        var messages: [ChatMessage]
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message?
        }

        var choices: [Choice]?
    }
}

func authorize(_ request: inout URLRequest, _ config: EndpointConfig) {
    if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
}

/// Diarizing models label voices; Whisper models time their segments; others return plain text.
enum SegmentFormat: String {
    case diarizedJson = "diarized_json"
    case verboseJson = "verbose_json"
    case json

    init(model: String) {
        if model.matches("diariz", caseInsensitive: true) {
            self = .diarizedJson
        } else if model.matches("whisper", caseInsensitive: true) {
            self = .verboseJson
        } else {
            self = .json
        }
    }
}

struct TranscriptionResponse: Decodable {
    struct Segment: Decodable {
        var start: Double?
        var end: Double?
        var text: String?
        var speaker: String?
    }

    var text: String?
    var segments: [Segment]?
}

func parseSegments(_ json: TranscriptionResponse, durationMs: Double) -> [TranscriptSegment] {
    let clamp = { (seconds: Double?) in min(durationMs, max(0, ((seconds ?? 0) * 1000).rounded())) }
    let segments = (json.segments ?? [])
        .map { TranscriptSegment(startMs: clamp($0.start), endMs: clamp($0.end), text: ($0.text ?? "").trimmed, speaker: $0.speaker) }
        .filter { !$0.text.isEmpty }
    if !segments.isEmpty { return segments }
    let text = (json.text ?? "").trimmed
    return text.isEmpty ? [] : [TranscriptSegment(startMs: 0, endMs: durationMs, text: text)]
}

struct MultipartForm {
    let boundary = "openwispr-\(UUID().uuidString)"
    private(set) var body = Data()

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, type: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func request(_ url: @autoclosure () throws -> URL, config: EndpointConfig) rethrows -> URLRequest {
        var request = URLRequest(url: try url(), timeoutInterval: EndpointClient.timeout)
        request.httpMethod = "POST"
        authorize(&request, config)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var payload = body
        payload.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = payload
        return request
    }
}
