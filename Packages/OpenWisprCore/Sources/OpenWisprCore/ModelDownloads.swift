import CryptoKit
import Foundation
import Synchronization

public struct ManifestFile: Sendable, Equatable, Codable {
    public var file: HubFile
    /// Relative to the model's folder.
    public var localPath: String

    public init(file: HubFile, localPath: String) {
        self.file = file
        self.localPath = localPath
    }

    private enum CodingKeys: String, CodingKey { case localPath }

    public init(from decoder: any Decoder) throws {
        file = try HubFile(from: decoder)
        localPath = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .localPath)
    }

    public func encode(to encoder: any Encoder) throws {
        try file.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localPath, forKey: .localPath)
    }
}

/// Written into each model's folder; the engines read the folder, OpenWispr reads this.
public struct ModelManifest: Sendable, Equatable, Codable {
    public var entry: ModelEntry
    public var userAdded: Bool
    /// False while downloading or after an interruption; true once every file is verified.
    public var installed: Bool
    public var files: [ManifestFile]

    public init(entry: ModelEntry, userAdded: Bool, installed: Bool, files: [ManifestFile]) {
        self.entry = entry
        self.userAdded = userAdded
        self.installed = installed
        self.files = files
    }

    private enum CodingKeys: String, CodingKey { case userAdded, installed, files }

    public init(from decoder: any Decoder) throws {
        entry = try ModelEntry(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userAdded = try container.decodeIfPresent(Bool.self, forKey: .userAdded) ?? false
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        files = try container.decodeIfPresent([ManifestFile].self, forKey: .files) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        try entry.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userAdded, forKey: .userAdded)
        try container.encode(installed, forKey: .installed)
        try container.encode(files, forKey: .files)
    }
}

private let manifestName = "manifest.json"
private let partSuffix = ".part"
private let maxAttempts = 5
private let progressIntervalMs = 250.0
private let skipped = #"(^|/)(\.gitattributes|[^/]*\.md|[^/]*\.(png|jpe?g|gif|webp|svg))$"#

/// Downloads Built-in models from Hugging Face into one folder per model, resuming and verifying files.
public actor ModelDownloads {
    private final class Job {
        var task: Task<Void, any Error>?
        var cancelled = false
        var bytesDone: Int64 = 0
        var totalBytes: Int64
        var bytesPerSecond: Double = 0
        var windowStart: Double
        var windowBytes: Int64 = 0
        var lastEmit: Double = 0

        init(totalBytes: Int64, now: Double) {
            self.totalBytes = totalBytes
            windowStart = now
        }
    }

    public nonisolated let directory: URL
    private let http: any HTTPClient
    private let hub: HuggingFace
    /// Files already there are copied instead of downloaded.
    private let hubCache: HubCache?
    /// Delay before the first retry of a dropped or stalled transfer; doubles on each further attempt.
    private let retryDelay: Duration
    /// A stalled body stream otherwise hangs forever without an error.
    private let stallTimeout: Duration
    private let onChange: @Sendable () -> Void
    /// Called before a model's files are deleted or replaced, so nothing still reads them.
    private let release: @Sendable (String) async -> Void
    private var jobs: [String: Job] = [:]
    private var errors: [String: String] = [:]

    public init(
        directory: URL, http: any HTTPClient, hubCache: HubCache? = nil, retryDelay: Duration = .seconds(1),
        stallTimeout: Duration = .seconds(30), onChange: @escaping @Sendable () -> Void, release: @escaping @Sendable (String) async -> Void
    ) {
        self.directory = directory
        self.http = http
        hub = HuggingFace(http: http)
        self.hubCache = hubCache
        self.retryDelay = retryDelay
        self.stallTimeout = stallTimeout
        self.onChange = onChange
        self.release = release
    }

    /// Returns when the model is installed or the download was cancelled; throws when it failed.
    public func start(_ entry: ModelEntry, userAdded: Bool) async throws {
        if let running = jobs[entry.id], let task = running.task {
            try await task.value
            return
        }
        let job = Job(totalBytes: entry.sizeBytes, now: epochMs())
        jobs[entry.id] = job
        errors[entry.id] = nil
        let task = Task { try await self.run(entry, userAdded: userAdded, job: job) }
        job.task = task
        onChange()
        defer {
            if jobs[entry.id] === job { jobs[entry.id] = nil }
            onChange()
        }
        do {
            try await task.value
        } catch {
            if job.cancelled { return }
            errors[entry.id] = errorMessage(error)
            throw error
        }
    }

    /// Stops a download and deletes what it fetched so far.
    public func cancel(_ id: String) async throws {
        try await stop(id)
        try? FileManager.default.removeItem(at: try folder(id))
        errors[id] = nil
        onChange()
    }

    /// Deletes the model's folder, stopping its download first; returns the bytes freed.
    @discardableResult
    public func remove(_ id: String) async throws -> Int64 {
        try await stop(id)
        let folder = try folder(id)
        let freed = folderSize(folder)
        try? FileManager.default.removeItem(at: folder)
        errors[id] = nil
        onChange()
        return freed
    }

    private func stop(_ id: String) async throws {
        _ = try folder(id)
        if let job = jobs[id] {
            job.cancelled = true
            job.task?.cancel()
            _ = try? await job.task?.value
        }
        await release(id)
    }

    public func state(_ id: String) -> DownloadState {
        if let job = jobs[id] {
            return .downloading(bytesDone: job.bytesDone, totalBytes: job.totalBytes, bytesPerSecond: job.bytesPerSecond)
        }
        guard let manifest = manifest(id) else { return .notDownloaded }
        let totalBytes = manifest.files.reduce(0) { $0 + $1.file.size }
        if manifest.installed { return .installed(sizeBytes: totalBytes) }
        return .paused(bytesDone: bytesOnDisk(id, manifest.files), totalBytes: totalBytes, error: errors[id])
    }

    /// Every model with a folder, installed or not.
    public func manifests() -> [ModelManifest] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { manifest($0.lastPathComponent) }
    }

    public func diskUsage() -> Int64 { folderSize(directory) }

    public nonisolated func folder(_ id: String) throws -> URL {
        let folder = directory.appending(path: id).standardizedFileURL
        guard !id.isEmpty, !id.contains("/"), folder.deletingLastPathComponent().path == directory.standardizedFileURL.path else {
            throw AppError("Invalid model id \(id)")
        }
        return folder
    }

    private func manifest(_ id: String) -> ModelManifest? {
        guard let folder = try? folder(id) else { return nil }
        return readJson(folder.appending(path: manifestName), as: ModelManifest.self)
    }

    private func run(_ entry: ModelEntry, userAdded: Bool, job: Job) async throws {
        var files: [ManifestFile] = []
        for source in entry.sources { files += try await plan(source) }
        let folder = try folder(entry.id)
        var manifest = ModelManifest(entry: entry, userAdded: userAdded, installed: false, files: files)
        let manifestURL = folder.appending(path: manifestName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if var previous = self.manifest(entry.id) {
            // Keep the previous hashes on disk until cleanup succeeds, so an interrupted update can
            // still identify stale files when it resumes.
            previous.installed = false
            writeJsonAtomic(manifestURL, previous)
            await release(entry.id)
            removeStale(folder, previous: previous.files, files: files)
        }
        writeJsonAtomic(manifestURL, manifest)
        job.totalBytes = files.reduce(0) { $0 + $1.file.size }
        job.bytesDone = bytesOnDisk(entry.id, files)
        for file in files { try await fetchFile(folder, file, jobId: entry.id, job: job) }
        manifest.installed = true
        writeJsonAtomic(manifestURL, manifest)
    }

    private func plan(_ source: ModelSource) async throws -> [ManifestFile] {
        let listed = try await hub.listRepoFiles(repo: source.repo, revision: source.revision, folder: source.folder)
        let wants = { (wanted: String, file: HubFile) in wanted.hasSuffix("/") ? file.path.hasPrefix(wanted) : file.path == wanted }
        let picked = if let wanted = source.files {
            listed.filter { file in wanted.contains { wants($0, file) } }
        } else {
            listed.filter { !$0.path.matches(skipped, caseInsensitive: true) }
        }
        for wanted in source.files ?? [] where !picked.contains(where: { wants(wanted, $0) }) {
            throw AppError("\(wanted) is missing from \(source.repo)")
        }
        return try picked.map { file in
            let localPath = source.folder.map { String(file.path.dropFirst($0.count + 1)) } ?? file.path
            if localPath.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) {
                throw AppError("Unsafe file path \(file.path)")
            }
            return ManifestFile(file: file, localPath: localPath)
        }
    }

    private func fetchFile(_ folder: URL, _ manifestFile: ManifestFile, jobId: String, job: Job) async throws {
        let file = manifestFile.file
        let target = folder.appending(path: manifestFile.localPath)
        let part = URL(filePath: target.path + partSuffix)
        // Files are only renamed into place after verification.
        if sizeOf(target) == file.size { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if copyFromCache(file, part: part, job: job) {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: part, to: target)
            return
        }
        var attempt = 1
        while true {
            let before = sizeOf(part) ?? 0
            do {
                try await transfer(file, part: part, have: before, jobId: jobId)
                break
            } catch {
                if job.cancelled || Task.isCancelled { throw CancellationError() }
                if let error = error as? HubError, !error.retryable { throw error }
                if (sizeOf(part) ?? 0) > before { attempt = 1 }
                if attempt >= maxAttempts { throw error }
                try await Task.sleep(for: retryDelay * (1 << (attempt - 1)))
                attempt += 1
            }
        }
        if !matches(part, file) {
            try? FileManager.default.removeItem(at: part)
            job.bytesDone -= file.size
            throw AppError("\(file.path) didn't match its published \(file.sha256 != nil ? "SHA-256" : "Git hash"), so it was discarded")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: part, to: target)
    }

    /// Copies `file` from the Hugging Face cache into `part`, replacing a partial download, when a verified
    /// copy is there. On APFS the copy is a clone, so it takes no extra space.
    private func copyFromCache(_ file: HubFile, part: URL, job: Job) -> Bool {
        guard !job.cancelled, let blob = hubCache?.blob(for: file), matches(blob, file) else { return false }
        let before = sizeOf(part) ?? 0
        try? FileManager.default.removeItem(at: part)
        guard (try? FileManager.default.copyItem(at: blob, to: part)) != nil, sizeOf(part) == file.size else {
            try? FileManager.default.removeItem(at: part)
            job.bytesDone -= before
            return false
        }
        progress(job, file.size - before)
        return true
    }

    /// Appends the rest of `file` to `part`, which already holds `have` bytes, failing when no data arrives for `stallTimeout`.
    private func transfer(_ file: HubFile, part: URL, have: Int64, jobId: String) async throws {
        let activity = Activity()
        let timeout = stallTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.receive(file, part: part, have: have, jobId: jobId, activity: activity) }
            group.addTask {
                while true {
                    try await Task.sleep(for: min(timeout, .seconds(1)))
                    if activity.idle >= timeout { throw AppError("Download stalled") }
                }
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func receive(_ file: HubFile, part: URL, have: Int64, jobId: String, activity: Activity) async throws {
        guard let job = jobs[jobId] else { throw CancellationError() }
        guard let url = URL(string: resolveUrl(repo: file.repo, revision: file.revision, path: file.path)) else {
            throw AppError("Invalid URL for \(file.path)")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(hubUserAgent, forHTTPHeaderField: "User-Agent")
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }

        let (response, body) = try await http.stream(for: request)
        activity.touch()
        if response.statusCode == 416 { return }
        guard (200..<300).contains(response.statusCode) else { throw hubError(response, repo: file.repo, path: file.path) }
        var offset = have
        if response.statusCode == 206 {
            let total = response.value(forHTTPHeaderField: "Content-Range")?.firstMatch(#"/(\d+)$"#)?[1].flatMap { Int64($0) }
            if total != file.size {
                try Data().write(to: part)
                job.bytesDone -= have
                throw AppError("\(file.path) changed on the server")
            }
        } else {
            // The server ignored the range, so start over.
            offset = 0
            job.bytesDone -= have
        }
        if offset == 0 { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for try await chunk in body {
            activity.touch()
            if job.cancelled || Task.isCancelled { throw CancellationError() }
            offset += Int64(chunk.count)
            if offset > file.size {
                try handle.truncate(atOffset: 0)
                job.bytesDone -= offset - Int64(chunk.count)
                // Not retryable: the same file would overrun again.
                throw HubError(message: "\(file.path) is larger than Hugging Face lists it, so it was discarded", status: response.statusCode, code: nil)
            }
            try handle.write(contentsOf: chunk)
            progress(job, Int64(chunk.count))
        }
        if job.cancelled || Task.isCancelled { throw CancellationError() }
    }

    private func progress(_ job: Job, _ bytes: Int64) {
        job.bytesDone += bytes
        job.windowBytes += bytes
        let now = epochMs()
        if now - job.windowStart >= 1000 {
            job.bytesPerSecond = (Double(job.windowBytes) * 1000 / (now - job.windowStart)).rounded()
            job.windowStart = now
            job.windowBytes = 0
        }
        if now - job.lastEmit >= progressIntervalMs {
            job.lastEmit = now
            onChange()
        }
    }

    private func bytesOnDisk(_ id: String, _ files: [ManifestFile]) -> Int64 {
        guard let folder = try? folder(id) else { return 0 }
        return files.reduce(0) { sum, file in
            let target = folder.appending(path: file.localPath)
            return sum + (sizeOf(target) ?? sizeOf(URL(filePath: target.path + partSuffix)) ?? 0)
        }
    }
}

/// Checks the published size, then SHA-256 for LFS files or the git blob SHA-1 for the rest.
func matches(_ url: URL, _ file: HubFile) -> Bool {
    guard sizeOf(url) == file.size, let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let digest: String
    if let sha256 = file.sha256 {
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        digest = hash.finalize().hex
        return digest == sha256
    }
    var hash = Insecure.SHA1()
    hash.update(data: Data("blob \(file.size)\0".utf8))
    while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
    digest = hash.finalize().hex
    return digest == file.gitOid
}

private final class Activity: Sendable {
    private let last = Mutex(ContinuousClock.now)

    func touch() { last.withLock { $0 = .now } }

    var idle: Duration { ContinuousClock.now - last.withLock { $0 } }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Files are skipped once their size matches, so when a model is downloaded again at another revision,
/// delete those of the earlier one that changed or are gone, once its manifest says it isn't installed.
private func removeStale(_ folder: URL, previous: [ManifestFile], files: [ManifestFile]) {
    let current = Dictionary(files.map { ($0.localPath, $0.file) }, uniquingKeysWith: { first, _ in first })
    for old in previous {
        let next = current[old.localPath]
        guard next == nil || next?.gitOid != old.file.gitOid || next?.sha256 != old.file.sha256 else { continue }
        let target = folder.appending(path: old.localPath)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: URL(filePath: target.path + partSuffix))
    }
}

func sizeOf(_ url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
    return (attributes[.size] as? NSNumber)?.int64Value
}

func folderSize(_ url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
    }
    return total
}
