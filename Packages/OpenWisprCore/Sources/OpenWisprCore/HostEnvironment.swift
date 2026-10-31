import Foundation
import Synchronization

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    /// `env` exits with 127 when it can't find the command on PATH.
    public var notFound: Bool { status == 127 }
    public var errorText: String { String(decoding: stderr, as: UTF8.self).trimmed }
}

/// Runs programs, injectable so tests answer them.
public protocol CommandRunner: Sendable {
    /// Runs `command`, looked up on `environment`'s PATH unless it's a path. Throws when it can't start or outlives `timeout`.
    func run(_ command: String, _ arguments: [String], environment: [String: String], timeout: Duration) async throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunner {
    /// How long output may keep arriving after the program exits, from children it left running.
    private static let drainGrace = Duration.seconds(1)

    public init() {}

    public func run(_ command: String, _ arguments: [String], environment: [String: String], timeout: Duration) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe
        let (exits, exit) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { finished in
            exit.yield(finished.terminationStatus)
            exit.finish()
        }
        try process.run()
        let status = try await withThrowingTaskGroup(of: Int32?.self) { group in
            group.addTask { await exits.first { _ in true } }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let status else {
            process.terminate()
            throw AppError("\(command) didn't finish within \(timeout.components.seconds) seconds")
        }
        return CommandResult(status: status, stdout: await stdout.collected(within: Self.drainGrace), stderr: await stderr.collected(within: Self.drainGrace))
    }
}

private final class OutputCollector: Sendable {
    let pipe = Pipe()
    private let state = Mutex((data: Data(), closed: false))

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            state.withLock {
                if chunk.isEmpty { $0.closed = true } else { $0.data.append(chunk) }
            }
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
    }

    func collected(within grace: Duration) async -> Data {
        let deadline = ContinuousClock.now + grace
        while !state.withLock(\.closed), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        return state.withLock(\.data)
    }
}

/// The user's environment as their terminal has it. A Mac app opened from the Dock gets launchd's variables,
/// not the ones the login shell exports, so those are read from the shell once, when first needed.
public actor HostEnvironment {
    private static let shellTimeout = Duration.seconds(5)
    private static let marker = "__OPENWISPR_ENV__"

    public nonisolated let home: URL
    private let launchVariables: [String: String]
    private let runner: any CommandRunner
    private let readsLoginShell: Bool
    private var loading: Task<[String: String], Never>?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, variables: [String: String] = ProcessInfo.processInfo.environment,
        runner: any CommandRunner = ProcessCommandRunner(), readsLoginShell: Bool = true
    ) {
        self.home = home
        launchVariables = variables
        self.runner = runner
        self.readsLoginShell = readsLoginShell
    }

    public func variables() async -> [String: String] {
        if let loading { return await loading.value }
        let load = Task { await self.load() }
        loading = load
        return await load.value
    }

    /// Reads the shell again on next use, to pick up variables exported since.
    public func reload() {
        loading = nil
    }

    /// Runs `command` with the user's environment, so it's found on their PATH.
    public func run(_ command: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        try await runner.run(command, arguments, environment: await variables(), timeout: timeout)
    }

    /// A file under the home folder, or where `variable` points when it's set.
    func path(_ variable: String, default relative: String) async -> URL {
        if let custom = await variables()[variable]?.trimmed, !custom.isEmpty {
            return URL(filePath: (custom as NSString).expandingTildeInPath)
        }
        return home.appending(path: relative)
    }

    private func load() async -> [String: String] {
        guard readsLoginShell else { return launchVariables }
        let shell = launchVariables["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = "printf '%s' \(Self.marker); /usr/bin/env -0; printf '%s' \(Self.marker)"
        do {
            let result = try await runner.run(shell, ["-ilc", script], environment: launchVariables, timeout: Self.shellTimeout)
            guard let shellVariables = parseEnvironment(result.stdout, marker: Self.marker) else {
                print("openwispr: couldn't read the login shell's environment: \(result.errorText)")
                return launchVariables
            }
            return launchVariables.merging(shellVariables) { _, shell in shell }
        } catch {
            print("openwispr: couldn't read the login shell's environment: \(errorMessage(error))")
            return launchVariables
        }
    }
}

/// `env -0` output between two markers, which keep out whatever the shell's startup files print.
func parseEnvironment(_ output: Data, marker: String) -> [String: String]? {
    let text = String(decoding: output, as: UTF8.self)
    let parts = text.components(separatedBy: marker)
    guard parts.count >= 3 else { return nil }
    var variables: [String: String] = [:]
    for entry in parts[1].split(separator: "\0") {
        guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
        variables[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
    }
    return variables
}

/// An INI file like `~/.aws/config` or a gcloud configuration, by section and lowercased key.
struct IniFile {
    var sections: [(name: String, values: [String: String])]

    init(_ text: String) {
        sections = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmed
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((name: String(line.dropFirst().dropLast()).trimmed, values: [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty {
                let key = String(line[..<equals]).trimmed.lowercased()
                sections[sections.count - 1].values[key] = String(line[line.index(after: equals)...]).trimmed
            }
        }
    }

    init?(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.init(text)
    }

    subscript(section: String) -> [String: String]? {
        sections.first { $0.name == section }?.values
    }
}
