import Foundation
import Security
import Synchronization
import Testing
@testable import OpenWisprCore

/// Programs that answer from a script, recording each command line.
private final class FakeCommands: CommandRunner {
    private let log = Mutex<[[String]]>([])
    private let reply: @Sendable ([String]) -> CommandResult

    init(_ reply: @escaping @Sendable ([String]) -> CommandResult = { _ in CommandResult(status: 127) }) {
        self.reply = reply
    }

    var calls: [[String]] { log.withLock { $0 } }

    func run(_ command: String, _ arguments: [String], environment: [String: String], timeout: Duration) async throws -> CommandResult {
        let line = [command] + arguments
        log.withLock { $0.append(line) }
        return reply(line)
    }
}

private let haiku = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
private let exampleKeys = ["AWS_ACCESS_KEY_ID": "AKIDEXAMPLE", "AWS_SECRET_ACCESS_KEY": "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"]
/// 2015-08-30T12:36:00Z, the date of AWS's Signature Version 4 test suite.
private let suiteDate = Date(timeIntervalSince1970: 1_440_938_160)

private func converseReply(_ text: String) -> FakeResponse {
    .json(#"{"output":{"message":{"role":"assistant","content":[{"text":"\#(text)"}]}},"stopReason":"end_turn"}"#)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@MainActor
private func chatSettings(_ selection: ModelSelection) -> SettingsBox {
    var settings = Settings()
    settings.chat = selection
    return SettingsBox(settings)
}

@Suite("Host environment")
struct HostEnvironmentTests {
    @Test func `reads variables between the markers, ignoring what startup files print`() {
        let output = Data("Last login: today\n@@\("HOME=/Users/jane\0AWS_PROFILE=work\0EMPTY=\0WITH=EQ=UALS\0")@@\nbye".utf8)
        #expect(parseEnvironment(output, marker: "@@") == ["HOME": "/Users/jane", "AWS_PROFILE": "work", "EMPTY": "", "WITH": "EQ=UALS"])
        #expect(parseEnvironment(Data("no markers".utf8), marker: "@@") == nil)
    }

    @Test func `layers the login shell's variables over the app's, reading the shell once until reloaded`() async throws {
        let commands = FakeCommands { line in
            let marker = line.last?.firstMatch(#"printf '%s' (\S+);"#)?[1] ?? ""
            return CommandResult(status: 0, stdout: Data("\(marker)PATH=/opt/homebrew/bin\0AWS_PROFILE=work\0\(marker)".utf8))
        }
        let host = HostEnvironment(home: URL(filePath: "/tmp"), variables: ["PATH": "/usr/bin", "SHELL": "/bin/zsh", "LANG": "en"], runner: commands)
        #expect(await host.variables() == ["PATH": "/opt/homebrew/bin", "SHELL": "/bin/zsh", "LANG": "en", "AWS_PROFILE": "work"])
        _ = await host.variables()
        #expect(commands.calls.count == 1)
        #expect(commands.calls.first?.prefix(2) == ["/bin/zsh", "-ilc"])
        await host.reload()
        _ = await host.variables()
        #expect(commands.calls.count == 2)
    }

    @Test func `keeps the app's variables when the shell fails`() async {
        let host = HostEnvironment(home: URL(filePath: "/tmp"), variables: ["PATH": "/usr/bin"], runner: FakeCommands { _ in CommandResult(status: 1) })
        #expect(await host.variables() == ["PATH": "/usr/bin"])
    }

    @Test func `runs real programs with the given environment and collects their output`() async throws {
        let result = try await ProcessCommandRunner().run(
            "/bin/sh", ["-c", "printf \"$GREETING\"; printf oops >&2; exit 3"], environment: ["GREETING": "hello"], timeout: .seconds(10)
        )
        #expect(result == CommandResult(status: 3, stdout: Data("hello".utf8), stderr: Data("oops".utf8)))
        let missing = try await ProcessCommandRunner().run("openwispr-no-such-program", [], environment: ["PATH": "/usr/bin"], timeout: .seconds(10))
        #expect(missing.notFound)
    }

    @Test func `parses INI sections, skipping comments`() {
        let file = IniFile("# comment\n[default]\nregion = us-west-2\n\n[profile work]\n; note\nSSO_Session=corp\nregion=eu-central-1\n")
        #expect(file.sections.map(\.name) == ["default", "profile work"])
        #expect(file["profile work"] == ["sso_session": "corp", "region": "eu-central-1"])
        #expect(file["default"]?["region"] == "us-west-2")
    }
}

@Suite("Signature Version 4")
struct SignatureV4Tests {
    private let credentials = AWSCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")

    @Test func `matches AWS's test suite for a plain GET`() throws {
        var request = URLRequest(url: try #require(URL(string: "https://example.amazonaws.com/")))
        signV4(&request, credentials: credentials, region: "us-east-1", service: "service", date: suiteDate)
        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
            + "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func `sorts and encodes query parameters like botocore`() throws {
        var request = URLRequest(url: try #require(URL(string: "https://example.amazonaws.com/?Param2=value2&Param1=value%201")))
        signV4(&request, credentials: credentials, region: "us-east-1", service: "service", date: suiteDate)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasSuffix("Signature=ef50c793b5e6d10be6882150088b3c59c29be8c3d8e67468b1a2255c07e4f31f") == true)
    }

    @Test func `signs a Converse request like botocore, encoding the model id twice and including the session token`() throws {
        let url = try #require(URL(string: "https://bedrock-runtime.us-west-2.amazonaws.com/model/\(awsEncode(haiku))/converse"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"messages":[{"role":"user","content":[{"text":"hi"}]}]}"#.utf8)
        var withToken = credentials
        withToken.sessionToken = "session-token"
        signV4(&request, credentials: withToken, region: "us-west-2", service: "bedrock", date: suiteDate)
        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "session-token")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-west-2/bedrock/aws4_request, "
            + "SignedHeaders=content-type;host;x-amz-date;x-amz-security-token, Signature=f6e6b6412c594c6edd46e369f1217f8ec8b723ad56e2764687888aa81b947088") // gitleaks:allow
    }
}

@MainActor
@Suite("Amazon Bedrock")
struct BedrockTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    private func host(_ variables: [String: String], commands: FakeCommands = FakeCommands()) -> HostEnvironment {
        HostEnvironment(home: directory, variables: variables, runner: commands, readsLoginShell: false)
    }

    @Test func `sends chat to the Converse API with the environment's keys, as one user turn after the system prompt`() async throws {
        let http = FakeHub { _, _ in converseReply("Tidy text.") }
        let variables = exampleKeys.merging(["AWS_SESSION_TOKEN": "token", "AWS_REGION": "us-west-2"]) { $1 }
        let models = await makeModels(http, settings: chatSettings(.bedrock(BedrockConfig(model: haiku))), directory: directory, host: host(variables))
        #expect(models.availability(.chat) == .available)
        #expect(try await models.complete([.system("Be brief."), .user("Context"), .user("tidy text")]) == "Tidy text.")
        let sent = try #require(http.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url == "https://bedrock-runtime.us-west-2.amazonaws.com/model/global.anthropic.claude-haiku-4-5-20251001-v1%3A0/converse")
        #expect(sent.authorization?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/") == true)
        #expect(sent.authorization?.contains("/us-west-2/bedrock/aws4_request") == true)
        #expect(sent.headers["X-Amz-Security-Token"] == "token")
        let json = try #require(sent.json)
        #expect(json["system"] as? [[String: String]] == [["text": "Be brief."]])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? [[String: String]] == [["text": "Context"], ["text": "tidy text"]])
    }

    @Test func `prefers a Bedrock API key from the environment`() async throws {
        let http = FakeHub { _, _ in converseReply("ok") }
        let variables = exampleKeys.merging(["AWS_BEARER_TOKEN_BEDROCK": "bedrock-key"]) { $1 }
        let models = await makeModels(http, settings: chatSettings(.bedrock(BedrockConfig(model: haiku))), directory: directory, host: host(variables))
        _ = try await models.complete([.user("hi")])
        #expect(http.requests.first?.authorization == "Bearer bedrock-key")
        #expect(http.requests.first?.url.hasPrefix("https://bedrock-runtime.us-east-1.amazonaws.com/") == true)
    }

    @Test func `gets a profile's credentials from the AWS CLI once, in the profile's region`() async throws {
        try write("[default]\nregion = us-east-2\n[profile work]\nsso_session = corp\nregion = eu-central-1\n", to: directory.appending(path: ".aws/config"))
        let commands = FakeCommands { line in
            guard line == ["aws", "configure", "export-credentials", "--profile", "work", "--format", "process"] else { return CommandResult(status: 2) }
            let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            let json = #"{"Version":1,"AccessKeyId":"ASIAWORK","SecretAccessKey":"secret","SessionToken":"sso-token","Expiration":"\#(expires)"}"#
            return CommandResult(status: 0, stdout: Data(json.utf8))
        }
        let http = FakeHub { _, _ in converseReply("ok") }
        let settings = chatSettings(.bedrock(BedrockConfig(model: haiku, profile: "work")))
        let models = await makeModels(http, settings: settings, directory: directory, host: host(exampleKeys, commands: commands))
        _ = try await models.complete([.user("hi")])
        _ = try await models.complete([.user("again")])
        #expect(commands.calls.count == 1)
        #expect(http.requests.map(\.url).allSatisfy { $0.hasPrefix("https://bedrock-runtime.eu-central-1.amazonaws.com/") })
        #expect(http.requests.first?.authorization?.hasPrefix("AWS4-HMAC-SHA256 Credential=ASIAWORK/") == true)
        #expect(http.requests.first?.headers["X-Amz-Security-Token"] == "sso-token")
        #expect(await models.bedrockRegion(BedrockConfig(profile: "work")) == "eu-central-1")
        #expect(await models.bedrockRegion(BedrockConfig()) == "us-east-2")
        #expect(await models.bedrockRegion(BedrockConfig(region: "ap-south-1", profile: "work")) == "ap-south-1")
    }

    @Test func `uses AWS_PROFILE when no profile is chosen and the environment has no keys`() async throws {
        let commands = FakeCommands { line in
            CommandResult(status: 0, stdout: Data((line.contains("from-env") ? #"{"AccessKeyId":"AKIAENV","SecretAccessKey":"s"}"# : "").utf8))
        }
        let http = FakeHub { _, _ in converseReply("ok") }
        let host = host(["AWS_PROFILE": "from-env"], commands: commands)
        let models = await makeModels(http, settings: chatSettings(.bedrock(BedrockConfig(model: haiku))), directory: directory, host: host)
        _ = try await models.complete([.user("hi")])
        #expect(http.requests.first?.authorization?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAENV/") == true)
    }

    @Test func `explains a missing AWS CLI, a profile it can't sign in to, and Bedrock's own errors`() async throws {
        let settings = chatSettings(.bedrock(BedrockConfig(model: haiku, profile: "work")))
        let noCli = await makeModels(settings: settings, directory: directory, host: host([:]))
        await #expect(throws: AppError("Install the AWS CLI to use AWS profiles, or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY")) {
            try await noCli.complete([.user("hi")])
        }

        let expired = FakeCommands { _ in
            CommandResult(status: 255, stderr: Data("\nThe SSO session associated with this profile has expired. To refresh this SSO session run aws sso login.\n".utf8))
        }
        let signedOut = await makeModels(settings: settings, directory: directory, host: host([:], commands: expired))
        #expect(await signedOut.testEndpoint(.chat) == .failed(
            "AWS profile work: The SSO session associated with this profile has expired. To refresh this SSO session run aws sso login."
        ))
        let refreshFailed = FakeCommands { _ in
            CommandResult(status: 255, stderr: Data("\naws: [ERROR]: Error when retrieving token from sso: Token has expired and refresh failed\n".utf8))
        }
        let stale = await makeModels(settings: settings, directory: directory, host: host([:], commands: refreshFailed))
        #expect(await stale.testEndpoint(.chat) == .failed(
            "AWS profile work: Error when retrieving token from sso: Token has expired and refresh failed. Run aws sso login --profile work"
        ))

        let http = FakeHub { _, _ in .json(#"{"message":"You don't have access to the model with the specified model ID."}"#, status: 403) }
        let denied = await makeModels(http, settings: chatSettings(.bedrock(BedrockConfig(model: haiku))), directory: directory, host: host(exampleKeys))
        #expect(await denied.testEndpoint(.chat) == .failed("Chat failed (403): You don't have access to the model with the specified model ID."))
    }

    @Test func `serves chat only, and needs a model`() async throws {
        var settings = Settings()
        settings.speechToText = .bedrock(BedrockConfig())
        settings.chat = .bedrock(BedrockConfig(model: " "))
        let models = await makeModels(settings: SettingsBox(settings), directory: directory)
        #expect(models.availability(.speechToText) == .unavailable("Amazon Bedrock only serves chat models here. Choose another speech-to-text model in Settings"))
        #expect(models.availability(.chat) == .unavailable("Set up a chat model in Settings"))
        await #expect(throws: AppError("Amazon Bedrock only serves chat models here. Choose another speech-to-text model in Settings")) {
            try await models.transcribe(Data(), prompt: "")
        }
    }

    @Test func `lists the AWS CLI's profiles, default first`() async throws {
        try write("[profile zeta]\n[default]\n[sso-session corp]\n[profile alpha]\n", to: directory.appending(path: ".aws/config"))
        try write("[default]\n[ci]\n", to: directory.appending(path: ".aws/credentials"))
        let models = await makeModels(directory: directory, host: host([:]))
        #expect(await models.awsProfiles() == ["default", "alpha", "ci", "zeta"])
    }
}

@MainActor
@Suite("Google Cloud")
struct GoogleCloudTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    private var gcloud: URL { directory.appending(path: ".config/gcloud") }

    private func host(_ variables: [String: String] = [:]) -> HostEnvironment {
        HostEnvironment(home: directory, variables: variables, runner: FakeCommands(), readsLoginShell: false)
    }

    private func signInWithGcloud(project: String? = "my-project") throws {
        try write(
            #"{"type":"authorized_user","client_id":"client","client_secret":"shh","refresh_token":"refresh/1"}"#,
            to: gcloud.appending(path: "application_default_credentials.json")
        )
        try write("work\n", to: gcloud.appending(path: "active_config"))
        if let project { try write("[core]\naccount = jane@example.com\nproject = \(project)\n", to: gcloud.appending(path: "configurations/config_work")) }
    }

    private func server(token: String = "ya29.token") -> FakeHub {
        FakeHub { path, _ in
            path == "/token" ? .json(#"{"access_token":"\#(token)","expires_in":3599,"token_type":"Bearer"}"#)
                : .json(#"{"choices":[{"message":{"content":"Tidy text."}}]}"#)
        }
    }

    @Test func `signs in with gcloud's credentials and sends chat to the global OpenAI-compatible endpoint of gcloud's project`() async throws {
        try signInWithGcloud()
        let http = server()
        let models = await makeModels(http, settings: chatSettings(.googleCloud(GoogleCloudConfig())), directory: directory, host: host())
        #expect(models.availability(.chat) == .available)
        #expect(try await models.complete([.user("tidy text")]) == "Tidy text.")
        _ = try await models.complete([.user("again")])
        let token = try #require(http.requests.first)
        #expect(token.url == "https://oauth2.googleapis.com/token")
        #expect(token.method == "POST")
        #expect(String(decoding: token.body ?? Data(), as: UTF8.self)
            == "grant_type=refresh_token&client_id=client&client_secret=shh&refresh_token=refresh%2F1")
        let chats = http.requests.dropFirst()
        #expect(chats.count == 2)
        #expect(chats.allSatisfy { $0.url == "https://aiplatform.googleapis.com/v1/projects/my-project/locations/global/endpoints/openapi/chat/completions" })
        #expect(chats.allSatisfy { $0.authorization == "Bearer ya29.token" })
        #expect(chats.first?.json?["model"] as? String == "google/gemini-3.5-flash")
    }

    @Test func `uses a regional endpoint, the configured project, and Google as the publisher of a bare model name`() async throws {
        try signInWithGcloud(project: nil)
        let http = server()
        let config = GoogleCloudConfig(model: "gemini-3.5-flash-lite", project: "other-project", location: "us-central1")
        let models = await makeModels(http, settings: chatSettings(.googleCloud(config)), directory: directory, host: host())
        _ = try await models.complete([.user("hi")])
        let chat = try #require(http.requests.last)
        #expect(chat.url == "https://us-central1-aiplatform.googleapis.com/v1/projects/other-project/locations/us-central1/endpoints/openapi/chat/completions")
        #expect(chat.json?["model"] as? String == "google/gemini-3.5-flash-lite")
    }

    @Test func `takes the project from GOOGLE_CLOUD_PROJECT before gcloud's`() async throws {
        try signInWithGcloud()
        let models = await makeModels(directory: directory, host: host(["GOOGLE_CLOUD_PROJECT": "env-project"]))
        #expect(await models.googleCloudProject(GoogleCloudConfig()) == "env-project")
        #expect(await models.googleCloudProject(GoogleCloudConfig(project: "set")) == "set")
    }

    @Test func `signs a service account's assertion with its key from GOOGLE_APPLICATION_CREDENTIALS`() async throws {
        let (pem, publicKey) = try serviceAccountKey()
        let file: [String: String] = [
            "type": "service_account", "project_id": "sa-project", "private_key_id": "key-1", "private_key": pem,
            "client_email": "bot@sa-project.iam.gserviceaccount.com", "token_uri": "https://oauth2.googleapis.com/token",
        ]
        let path = directory.appending(path: "sa.json")
        try JSONSerialization.data(withJSONObject: file).write(to: path)
        let http = server()
        let settings = chatSettings(.googleCloud(GoogleCloudConfig()))
        let models = await makeModels(http, settings: settings, directory: directory, host: host(["GOOGLE_APPLICATION_CREDENTIALS": path.path]))
        _ = try await models.complete([.user("hi")])

        let form = String(decoding: try #require(http.requests.first?.body), as: UTF8.self)
        let assertion = try #require(form.firstMatch(#"^grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=(.+)$"#)?[1])
        let parts = assertion.split(separator: ".").map(String.init)
        try #require(parts.count == 3)
        let header = try #require(try JSONSerialization.jsonObject(with: base64UrlDecoded(parts[0])) as? [String: String])
        #expect(header == ["alg": "RS256", "typ": "JWT", "kid": "key-1"])
        let claims = try #require(try JSONSerialization.jsonObject(with: base64UrlDecoded(parts[1])) as? [String: Any])
        #expect(claims["iss"] as? String == "bot@sa-project.iam.gserviceaccount.com")
        #expect(claims["aud"] as? String == "https://oauth2.googleapis.com/token")
        #expect(claims["scope"] as? String == "https://www.googleapis.com/auth/cloud-platform")

        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        #expect(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, base64UrlDecoded(parts[2]) as CFData, nil))
        #expect(http.requests.last?.url.contains("/projects/sa-project/") == true)
    }

    @Test func `says how to sign in when there are no credentials or Google refuses them`() async throws {
        let settings = chatSettings(.googleCloud(GoogleCloudConfig(project: "p")))
        let none = await makeModels(settings: settings, directory: directory, host: host())
        let hint = "Run gcloud auth application-default login, or set GOOGLE_APPLICATION_CREDENTIALS to a service account key file"
        let path = gcloud.appending(path: "application_default_credentials.json").path
        #expect(await none.testEndpoint(.chat) == .failed("No Google Cloud credentials at \(path). \(hint)"))

        try signInWithGcloud()
        let http = FakeHub { _, _ in .json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, status: 400) }
        let revoked = await makeModels(http, settings: settings, directory: directory, host: host())
        #expect(await revoked.testEndpoint(.chat) == .failed("Google Cloud sign-in failed: Token has been expired or revoked. \(hint)"))

        let forbidden = FakeHub { path, _ in
            path == "/token" ? .json(#"{"access_token":"t","expires_in":3599}"#)
                : .json(#"[{"error":{"code":403,"message":"Permission denied on resource project p.","status":"PERMISSION_DENIED"}}]"#, status: 403)
        }
        let denied = await makeModels(forbidden, settings: settings, directory: directory, host: host())
        #expect(await denied.testEndpoint(.chat) == .failed("Chat failed (403): Permission denied on resource project p."))
    }
}

private func base64UrlDecoded(_ text: String) -> Data {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64) ?? Data()
}

/// A fresh RSA key as the PKCS#8 PEM a service account key file holds, with its public key.
private func serviceAccountKey() throws -> (pem: String, publicKey: SecKey) {
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
    let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
    let pkcs1 = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
    func der(_ tag: UInt8, _ content: Data) -> Data {
        let count = content.count
        let length = count < 0x80 ? Data([UInt8(count)]) : Data([0x82, UInt8(count >> 8), UInt8(count & 0xFF)])
        return Data([tag]) + length + content
    }
    let rsaEncryption = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
    let pkcs8 = der(0x30, Data([0x02, 0x01, 0x00]) + der(0x30, rsaEncryption) + der(0x04, pkcs1))
    let body = pkcs8.base64EncodedString(options: .lineLength64Characters)
    let pem = "-----BEGIN PRIVATE KEY-----\n\(body)\n-----END PRIVATE KEY-----\n"
    return (pem, try #require(SecKeyCopyPublicKey(key)))
}

@MainActor
@Suite("OpenAI-compatible servers")
struct CompatibleServerTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    @Test func `lists the models a server offers, sorted, with its key`() async throws {
        let http = FakeHub { path, _ in
            path == "/v1/models" ? .json(#"{"object":"list","data":[{"id":"qwen3:8b"},{"id":"llama3.2:latest"},{}]}"#) : nil
        }
        var settings = Settings()
        settings.chat = .endpoint(EndpointConfig(baseUrl: "http://localhost:11434/v1/", model: "", apiKey: "local-key"))
        let models = await makeModels(http, settings: SettingsBox(settings), directory: directory)
        #expect(await models.endpointModels(.chat) == ["llama3.2:latest", "qwen3:8b"])
        #expect(http.requests.first?.url == "http://localhost:11434/v1/models")
        #expect(http.requests.first?.authorization == "Bearer local-key")
        #expect(await models.endpointModels(.speechToText).isEmpty)
    }

    @Test func `asks for a base URL when a custom server has none`() async throws {
        let models = await makeModels(settings: chatSettings(.endpoint(EndpointConfig(baseUrl: "", model: "", apiKey: ""))), directory: directory)
        #expect(await models.testEndpoint(.chat) == .failed("Enter the server's base URL, like http://localhost:8080/v1"))
    }

    @Test(arguments: [
        ("http://localhost:11434/v1", true), ("http://127.0.0.1:1234/v1", true), ("http://[::1]:8000/v1", true),
        ("http://gpu-box.local:8080/v1", true), ("http://192.168.1.20:8000/v1", true), ("http://10.0.0.5/v1", true),
        ("http://172.20.1.1/v1", true), ("http://172.32.1.1/v1", false), ("https://api.openai.com/v1", false),
        ("https://localhost.example.com/v1", false), ("ftp://localhost/v1", false), ("", false),
    ])
    func `treats servers on this Mac and the local network as needing no key`(url: String, local: Bool) {
        #expect(isLocalEndpoint(url) == local)
    }
}

@Suite("Cloud selections")
struct CloudSelectionTests {
    @Test func `round-trips Bedrock and Google Cloud selections through the settings file`() throws {
        var settings = Settings()
        settings.chat = .bedrock(BedrockConfig(model: haiku, region: "us-west-2", profile: "work"))
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.chat == settings.chat)
        settings.chat = .googleCloud(GoogleCloudConfig(model: "google/gemini-3.5-pro", project: "p", location: "europe-west4"))
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)).chat == settings.chat)
        let sparse = try JSONDecoder().decode(Settings.self, from: Data(#"{"chat":{"kind":"bedrock","model":"m"}}"#.utf8))
        #expect(sparse.chat == .bedrock(BedrockConfig(model: "m", region: "", profile: "")))
    }

    @Test func `starts a switch to Bedrock or Google Cloud from their defaults and keeps other fields on edits`() {
        let bedrock = ModelSelection.apple.applying(.bedrock())
        #expect(bedrock == .bedrock(BedrockConfig(model: BedrockConfig.defaultModel)))
        #expect(bedrock.applying(.bedrock(profile: "work")).applying(.bedrock(region: "eu-west-1"))
            == .bedrock(BedrockConfig(model: BedrockConfig.defaultModel, region: "eu-west-1", profile: "work")))
        let google = bedrock.applying(.googleCloud(project: "p"))
        #expect(google == .googleCloud(GoogleCloudConfig(model: GoogleCloudConfig.defaultModel, project: "p")))
        #expect(google.applying(.googleCloud(model: "google/gemini-3.5-pro")).googleCloud?.project == "p")
    }
}
