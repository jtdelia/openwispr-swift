import CryptoKit
import Foundation

public struct AWSCredentials: Sendable, Equatable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public var expiration: Date?

    public init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil, expiration: Date? = nil) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }
}

/// How a Bedrock request proves who sent it.
enum BedrockAuth: Sendable, Equatable {
    case signed(AWSCredentials)
    /// A Bedrock API key.
    case apiKey(String)
}

/// Finds AWS credentials like the AWS SDKs: a Bedrock API key or access keys in the environment, else a profile.
/// Profiles are resolved by the AWS CLI, so SSO, `aws login`, assumed roles and credential processes all work.
actor AWSCredentialResolver {
    private static let cliTimeout = Duration.seconds(30)
    /// Credentials this close to expiring are fetched again.
    private static let refreshMargin: TimeInterval = 5 * 60
    private static let defaultRegion = "us-east-1"

    private let host: HostEnvironment
    private let now: @Sendable () -> Date
    private var cache: [String: AWSCredentials] = [:]

    init(host: HostEnvironment, now: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.now = now
    }

    /// `profile` empty uses the environment's keys, then AWS_PROFILE or `default`.
    func auth(profile: String) async throws -> BedrockAuth {
        let env = await host.variables()
        let profile = profile.trimmed
        if profile.isEmpty {
            if let key = nonEmpty(env["AWS_BEARER_TOKEN_BEDROCK"]) { return .apiKey(key) }
            if let id = nonEmpty(env["AWS_ACCESS_KEY_ID"]), let secret = nonEmpty(env["AWS_SECRET_ACCESS_KEY"]) {
                return .signed(AWSCredentials(accessKeyId: id, secretAccessKey: secret, sessionToken: nonEmpty(env["AWS_SESSION_TOKEN"])))
            }
        }
        return .signed(try await profileCredentials(nonEmpty(profile) ?? defaultProfile(env)))
    }

    /// The configured region, else AWS_REGION, AWS_DEFAULT_REGION, the profile's region, then us-east-1.
    func region(_ config: BedrockConfig) async -> String {
        if let region = nonEmpty(config.region.trimmed) { return region }
        let env = await host.variables()
        if let region = nonEmpty(env["AWS_REGION"]) ?? nonEmpty(env["AWS_DEFAULT_REGION"]) { return region }
        let profile = nonEmpty(config.profile.trimmed) ?? defaultProfile(env)
        let section = profile == "default" ? "default" : "profile \(profile)"
        let file = IniFile(contentsOf: await host.path("AWS_CONFIG_FILE", default: ".aws/config"))
        return nonEmpty(file?[section]?["region"]) ?? Self.defaultRegion
    }

    /// Profiles in the AWS config and credentials files, `default` first.
    func profiles() async -> [String] {
        let config = IniFile(contentsOf: await host.path("AWS_CONFIG_FILE", default: ".aws/config"))?.sections.compactMap { section in
            section.name == "default" ? "default" : section.name.firstMatch(#"^profile\s+(.+)$"#)?[1]
        } ?? []
        let credentials = IniFile(contentsOf: await host.path("AWS_SHARED_CREDENTIALS_FILE", default: ".aws/credentials"))?.sections.map(\.name) ?? []
        return Set(config + credentials).sorted { ($0 == "default" ? 0 : 1, $0) < ($1 == "default" ? 0 : 1, $1) }
    }

    /// Forgets fetched credentials, so a fresh `aws sso login` is picked up.
    func reset() {
        cache = [:]
    }

    private func defaultProfile(_ env: [String: String]) -> String {
        nonEmpty(env["AWS_PROFILE"]) ?? nonEmpty(env["AWS_DEFAULT_PROFILE"]) ?? "default"
    }

    private func profileCredentials(_ profile: String) async throws -> AWSCredentials {
        if let cached = cache[profile], cached.expiration.map({ $0.timeIntervalSince(now()) > Self.refreshMargin }) ?? true { return cached }
        let result = try await host.run("aws", ["configure", "export-credentials", "--profile", profile, "--format", "process"], timeout: Self.cliTimeout)
        if result.notFound {
            throw AppError("Install the AWS CLI to use AWS profiles, or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY")
        }
        guard result.status == 0 else {
            let error = result.errorText.replacing(pattern: #"^aws: \[ERROR\]:\s*"#, with: "")
            var detail = error.isEmpty ? "the AWS CLI exited with status \(result.status)" : error
            if error.matches(#"\bsso\b"#, caseInsensitive: true), !error.contains("sso login") {
                detail += detail.hasSuffix(".") ? "" : "."
                detail += " Run aws sso login --profile \(profile)"
            }
            throw AppError("AWS profile \(profile): \(detail)")
        }
        guard let exported = try? JSONDecoder().decode(ExportedCredentials.self, from: result.stdout) else {
            throw AppError("AWS profile \(profile): the AWS CLI returned no credentials")
        }
        let credentials = AWSCredentials(
            accessKeyId: exported.accessKeyId, secretAccessKey: exported.secretAccessKey, sessionToken: exported.sessionToken,
            expiration: exported.expiration.flatMap(parseISO8601)
        )
        cache[profile] = credentials
        return credentials
    }

    /// What `aws configure export-credentials --format process` prints.
    private struct ExportedCredentials: Decodable {
        var accessKeyId: String
        var secretAccessKey: String
        var sessionToken: String?
        var expiration: String?

        enum CodingKeys: String, CodingKey {
            case accessKeyId = "AccessKeyId", secretAccessKey = "SecretAccessKey", sessionToken = "SessionToken", expiration = "Expiration"
        }
    }
}

/// Bedrock's Converse API, which speaks to every Bedrock chat model the same way.
struct BedrockClient: Sendable {
    let http: any HTTPClient
    let credentials: AWSCredentialResolver
    var now: @Sendable () -> Date = { Date() }

    func complete(_ config: BedrockConfig, messages: [ChatMessage], label: String, timeout: TimeInterval) async throws -> String {
        let model = config.model.trimmed
        guard !model.isEmpty else { throw AppError("Set a Bedrock model in Settings") }
        let region = await credentials.region(config)
        guard region.matches(#"^[a-z0-9-]+$"#), let url = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(awsEncode(model))/converse") else {
            throw AppError("Invalid AWS region: \(region)")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ConverseRequest(messages))
        switch try await credentials.auth(profile: config.profile) {
        case let .apiKey(key): request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case let .signed(credentials): signV4(&request, credentials: credentials, region: region, service: "bedrock", date: now())
        }
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(ErrorBody.self, from: data)
            let detail = error?.message ?? error?.capitalizedMessage ?? String(String(decoding: data, as: UTF8.self).prefix(300))
            throw AppError("\(label) failed (\(response.statusCode)): \(detail)")
        }
        let json = try? JSONDecoder().decode(ConverseResponse.self, from: data)
        return (json?.output?.message?.content ?? []).compactMap(\.text).joined()
    }

    private struct ErrorBody: Decodable {
        var message: String?
        var capitalizedMessage: String?

        enum CodingKeys: String, CodingKey { case message, capitalizedMessage = "Message" }
    }
}

struct ConverseRequest: Encodable {
    struct Text: Encodable { var text: String }
    struct Message: Encodable {
        var role: String
        var content: [Text]
    }

    var messages: [Message]
    var system: [Text]?

    /// Converse wants turns to alternate, so the user messages become one turn.
    init(_ chat: [ChatMessage]) {
        var system: [Text] = []
        var user: [Text] = []
        for message in chat {
            switch message.role {
            case .system: system.append(Text(text: message.content))
            case .user: user.append(Text(text: message.content))
            }
        }
        messages = [Message(role: "user", content: user)]
        self.system = system.isEmpty ? nil : system
    }
}

struct ConverseResponse: Decodable {
    struct Output: Decodable {
        struct Message: Decodable {
            struct Block: Decodable { var text: String? }
            var content: [Block]?
        }

        var message: Message?
    }

    var output: Output?
}

// MARK: Signature Version 4

private let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

/// Percent-encodes all but RFC 3986's unreserved characters, as AWS signing does.
func awsEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
}

/// Signs `request` with AWS Signature Version 4 for a service other than S3, whose paths are encoded twice.
func signV4(_ request: inout URLRequest, credentials: AWSCredentials, region: String, service: String, date: Date) {
    guard let url = request.url, let host = url.host() else { return }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
    let amzDate = formatter.string(from: date)
    let day = String(amzDate.prefix(8))
    request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
    if let token = credentials.sessionToken { request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token") }

    var headers = ["host": url.port.map { "\(host):\($0)" } ?? host]
    for (name, value) in request.allHTTPHeaderFields ?? [:] {
        headers[name.lowercased()] = value.trimmed.replacing(pattern: " +", with: " ")
    }
    let names = headers.keys.sorted()
    let signedHeaders = names.joined(separator: ";")
    let path = url.path(percentEncoded: true)
    let canonicalUri = path.isEmpty ? "/" : path.split(separator: "/", omittingEmptySubsequences: false).map { awsEncode(String($0)) }.joined(separator: "/")
    let canonicalQuery = (url.query(percentEncoded: true) ?? "").split(separator: "&").map { pair -> (String, String) in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? String($0) }
        return (awsEncode(parts[0]), awsEncode(parts.count > 1 ? parts[1] : ""))
    }.sorted { $0 < $1 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    let canonicalRequest = [
        request.httpMethod ?? "GET", canonicalUri, canonicalQuery,
        names.map { "\($0):\(headers[$0] ?? "")\n" }.joined(), signedHeaders, SHA256.hash(data: request.httpBody ?? Data()).hex,
    ].joined(separator: "\n")

    let scope = "\(day)/\(region)/\(service)/aws4_request"
    let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, SHA256.hash(data: Data(canonicalRequest.utf8)).hex].joined(separator: "\n")
    var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
    for part in [day, region, service, "aws4_request"] {
        key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
    }
    let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)).hex
    request.setValue(
        "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
        forHTTPHeaderField: "Authorization"
    )
}

// MARK: Helpers

func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmed, !value.isEmpty else { return nil }
    return value
}

/// Dates like `2026-10-28T06:00:00Z` or `2026-10-28T06:00:00.123+00:00`.
func parseISO8601(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
