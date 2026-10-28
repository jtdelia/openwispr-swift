import Foundation
import Security

private let signInHint = "Run gcloud auth application-default login, or set GOOGLE_APPLICATION_CREDENTIALS to a service account key file"

/// Signs in with Application Default Credentials: what `gcloud auth application-default login` saves, or the
/// service account key GOOGLE_APPLICATION_CREDENTIALS points to.
actor GoogleCredentialResolver {
    static let scope = "https://www.googleapis.com/auth/cloud-platform"
    private static let defaultTokenUri = "https://oauth2.googleapis.com/token"
    /// Tokens this close to expiring are fetched again.
    private static let refreshMargin: TimeInterval = 60
    private static let assertionLifetime: TimeInterval = 3600

    private let host: HostEnvironment
    private let http: any HTTPClient
    private let now: @Sendable () -> Date
    private var token: (value: String, expires: Date)?

    init(host: HostEnvironment, http: any HTTPClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.http = http
        self.now = now
    }

    func accessToken() async throws -> String {
        if let token, token.expires.timeIntervalSince(now()) > Self.refreshMargin { return token.value }
        let file = try await credentialsFile()
        let form: [(String, String)]
        switch file.type {
        case "authorized_user":
            guard let clientId = file.clientId, let clientSecret = file.clientSecret, let refreshToken = file.refreshToken else {
                throw AppError("Google Cloud credentials are incomplete. \(signInHint)")
            }
            form = [("grant_type", "refresh_token"), ("client_id", clientId), ("client_secret", clientSecret), ("refresh_token", refreshToken)]
        case "service_account":
            form = [("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"), ("assertion", try serviceAccountAssertion(file))]
        default:
            throw AppError("Google Cloud credentials of type \(file.type ?? "unknown") aren't supported. \(signInHint)")
        }
        guard let url = URL(string: file.tokenUri ?? Self.defaultTokenUri) else { throw AppError("Invalid token_uri in Google Cloud credentials") }
        var request = URLRequest(url: url, timeoutInterval: EndpointClient.timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { "\($0)=\(awsEncode($1))" }.joined(separator: "&").utf8)
        let (data, response) = try await http.data(for: request)
        let json = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard (200..<300).contains(response.statusCode), let value = json?.accessToken else {
            let detail = json?.errorDescription ?? json?.error ?? "status \(response.statusCode)"
            throw AppError("Google Cloud sign-in failed: \(detail.hasSuffix(".") ? String(detail.dropLast()) : detail). \(signInHint)")
        }
        token = (value, now().addingTimeInterval(json?.expiresIn ?? Self.assertionLifetime))
        return value
    }

    /// The configured project, else GOOGLE_CLOUD_PROJECT, CLOUDSDK_CORE_PROJECT, gcloud's active configuration,
    /// then the credentials' own project.
    func project(_ config: GoogleCloudConfig) async -> String? {
        if let project = nonEmpty(config.project) { return project }
        let env = await host.variables()
        if let project = nonEmpty(env["GOOGLE_CLOUD_PROJECT"]) ?? nonEmpty(env["CLOUDSDK_CORE_PROJECT"]) { return project }
        let configDirectory = await host.path("CLOUDSDK_CONFIG", default: ".config/gcloud")
        let active = nonEmpty(env["CLOUDSDK_ACTIVE_CONFIG_NAME"])
            ?? nonEmpty(try? String(contentsOf: configDirectory.appending(path: "active_config"), encoding: .utf8)) ?? "default"
        if let project = nonEmpty(IniFile(contentsOf: configDirectory.appending(path: "configurations/config_\(active)"))?["core"]?["project"]) {
            return project
        }
        let file = try? await credentialsFile()
        return nonEmpty(file?.quotaProjectId) ?? nonEmpty(file?.projectId)
    }

    /// Forgets the access token, so the credentials file is read again.
    func reset() {
        token = nil
    }

    private func credentialsFile() async throws -> CredentialsFile {
        let env = await host.variables()
        let url = if let path = nonEmpty(env["GOOGLE_APPLICATION_CREDENTIALS"]) {
            URL(filePath: (path as NSString).expandingTildeInPath)
        } else {
            await host.path("CLOUDSDK_CONFIG", default: ".config/gcloud").appending(path: "application_default_credentials.json")
        }
        guard let data = try? Data(contentsOf: url) else { throw AppError("No Google Cloud credentials at \(url.path). \(signInHint)") }
        guard let file = try? JSONDecoder().decode(CredentialsFile.self, from: data) else {
            throw AppError("Couldn't read the Google Cloud credentials at \(url.path)")
        }
        return file
    }

    private func serviceAccountAssertion(_ file: CredentialsFile) throws -> String {
        guard let email = file.clientEmail, let pem = file.privateKey, let key = rsaPrivateKey(pem: pem) else {
            throw AppError("The Google Cloud service account key has no usable private key")
        }
        let issued = Int(now().timeIntervalSince1970)
        var header = ["alg": "RS256", "typ": "JWT"]
        if let keyId = file.privateKeyId { header["kid"] = keyId }
        let claims: [String: Any] = [
            "iss": email, "scope": Self.scope, "aud": file.tokenUri ?? Self.defaultTokenUri,
            "iat": issued, "exp": issued + Int(Self.assertionLifetime),
        ]
        let headerJson = try JSONSerialization.data(withJSONObject: header, options: .sortedKeys)
        let claimsJson = try JSONSerialization.data(withJSONObject: claims, options: .sortedKeys)
        let signingInput = "\(base64Url(headerJson)).\(base64Url(claimsJson))"
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signingInput.utf8) as CFData, &error) else {
            throw AppError("Couldn't sign in with the Google Cloud service account: \(error?.takeRetainedValue().localizedDescription ?? "unknown error")")
        }
        return "\(signingInput).\(base64Url(signature as Data))"
    }

    private struct CredentialsFile: Decodable {
        var type: String?
        var clientId: String?
        var clientSecret: String?
        var refreshToken: String?
        var quotaProjectId: String?
        var projectId: String?
        var clientEmail: String?
        var privateKey: String?
        var privateKeyId: String?
        var tokenUri: String?

        enum CodingKeys: String, CodingKey {
            case type, clientId = "client_id", clientSecret = "client_secret", refreshToken = "refresh_token", quotaProjectId = "quota_project_id"
            case projectId = "project_id", clientEmail = "client_email", privateKey = "private_key", privateKeyId = "private_key_id"
            case tokenUri = "token_uri"
        }
    }

    private struct TokenResponse: Decodable {
        var accessToken: String?
        var expiresIn: TimeInterval?
        var error: String?
        var errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", expiresIn = "expires_in", error, errorDescription = "error_description"
        }
    }
}

/// Gemini Enterprise Agent Platform's OpenAI-compatible chat completions, with a Google Cloud access token as the key.
struct GoogleCloudClient: Sendable {
    let endpoints: EndpointClient
    let credentials: GoogleCredentialResolver

    func complete(_ config: GoogleCloudConfig, messages: [ChatMessage], label: String, timeout: TimeInterval) async throws -> String {
        let model = config.model.trimmed
        guard !model.isEmpty else { throw AppError("Set a Google Cloud model in Settings") }
        guard let project = await credentials.project(config) else {
            throw AppError("Set a Google Cloud project in Settings, or run gcloud config set project")
        }
        let location = nonEmpty(config.location)?.lowercased() ?? GoogleCloudConfig.defaultLocation
        guard location.matches(#"^[a-z0-9-]+$"#) else { throw AppError("Invalid Google Cloud location: \(location)") }
        guard project.matches(#"^[A-Za-z0-9.:-]+$"#) else { throw AppError("Invalid Google Cloud project: \(project)") }
        let host = location == "global" ? "aiplatform.googleapis.com" : "\(location)-aiplatform.googleapis.com"
        let endpoint = EndpointConfig(
            baseUrl: "https://\(host)/v1/projects/\(project)/locations/\(location)/endpoints/openapi",
            model: model.contains("/") ? model : "google/\(model)",
            apiKey: try await credentials.accessToken()
        )
        return try await endpoints.complete(endpoint, messages: messages, label: label, timeout: timeout)
    }
}

private func base64Url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// An RSA key from a PEM: PKCS #8 (`BEGIN PRIVATE KEY`, as Google issues) or PKCS #1 (`BEGIN RSA PRIVATE KEY`).
func rsaPrivateKey(pem: String) -> SecKey? {
    let body = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
    guard let der = Data(base64Encoded: body) else { return nil }
    guard let pkcs1 = pem.contains("BEGIN RSA PRIVATE KEY") ? der : pkcs1Key(fromPKCS8: der) else { return nil }
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
    return SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil)
}

/// The RSAPrivateKey inside a PKCS #8 PrivateKeyInfo; Security reads only the former.
private func pkcs1Key(fromPKCS8 der: Data) -> Data? {
    var outer = DERReader(bytes: Array(der))
    guard let info = outer.read(tag: 0x30) else { return nil }
    var inner = DERReader(bytes: info)
    guard inner.read(tag: 0x02) != nil, inner.read(tag: 0x30) != nil, let key = inner.read(tag: 0x04) else { return nil }
    return Data(key)
}

private struct DERReader {
    var bytes: [UInt8]
    var offset = 0

    /// The contents of the next element when it has `tag`.
    mutating func read(tag: UInt8) -> [UInt8]? {
        guard offset + 1 < bytes.count, bytes[offset] == tag else { return nil }
        var length = Int(bytes[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count <= 4, offset + count <= bytes.count else { return nil }
            length = bytes[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
            offset += count
        }
        guard offset + length <= bytes.count else { return nil }
        defer { offset += length }
        return Array(bytes[offset..<offset + length])
    }
}
