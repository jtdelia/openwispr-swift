import Foundation

/// A model in the Hugging Face cache that OpenWispr can run, found without the network. Adding it
/// installs the cached revision, so its files are cloned from the cache rather than downloaded.
public struct CachedModel: Sendable, Equatable, Identifiable {
    public var model: ModelEntry
    public var summary: String
    /// `oversized` as in `ModelStatus`.
    public var oversized: Bool

    public var id: String { model.id }

    public init(model: ModelEntry, summary: String, oversized: Bool) {
        self.model = model
        self.summary = summary
        self.oversized = oversized
    }
}

/// Every model in `cache` that passes the same check as a pasted repo, at the revision the cache holds.
/// Repos whose snapshot is missing files, like a lone weights file another tool fetched, aren't listed.
func discoverCachedModels(_ cache: HubCache) async -> [(model: ModelEntry, summary: String)] {
    let hub = CachedHub(cache: cache)
    var found: [(model: ModelEntry, summary: String)] = []
    for repo in hub.repos() {
        guard let revision = hub.cachedRevision(repo) else { continue }
        switch await checkHubRepo(hub, "\(repo)/tree/\(revision)") {
        case let .compatible(model, summary):
            found.append((model, summary))
        case let .severalModels(_, revision, folders, _):
            for folder in folders {
                if case let .compatible(model, summary) = await checkHubRepo(hub, "\(repo)/tree/\(revision)/\(folder)") {
                    found.append((model, summary))
                }
            }
        case .rejected:
            continue
        }
    }
    return found.sorted { ($0.model.task.rawValue, $0.model.name) < ($1.model.task.rawValue, $1.model.name) }
}

/// Reads repos from the cache's `models--<org>--<name>/snapshots/<sha>` folders, whose files link to blobs
/// named by their etag: the SHA-256 for Git LFS files, the Git blob SHA-1 for the rest.
struct CachedHub: HubRepoSource {
    let cache: HubCache

    /// Repo ids with at least one snapshot.
    func repos() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cache.directory.path)) ?? []
        return names.filter { $0.hasPrefix("models--") }.sorted().compactMap { name in
            let parts = name.dropFirst("models--".count).components(separatedBy: "--")
            guard parts.count >= 2 else { return nil }
            let repo = "\(parts[0])/\(parts.dropFirst().joined(separator: "--"))"
            return snapshots(repo).isEmpty ? nil : repo
        }
    }

    /// The snapshot `refs/main` points at, else the newest one.
    func cachedRevision(_ repo: String) -> String? {
        let all = snapshots(repo)
        if let main = try? String(contentsOf: folder(repo).appending(path: "refs/main"), encoding: .utf8).trimmed, all.contains(main) {
            return main
        }
        let modified = { (sha: String) in
            (try? FileManager.default.attributesOfItem(atPath: folder(repo).appending(path: "snapshots/\(sha)").path)[.modificationDate] as? Date) ?? .distantPast
        }
        return all.max { modified($0) < modified($1) }
    }

    func repoInfo(_ repo: String, revision: String?) async throws -> RepoInfo {
        let all = snapshots(repo)
        let named = (try? String(contentsOf: folder(repo).appending(path: "refs/\(revision ?? "main")"), encoding: .utf8))?.trimmed
        // Without a revision, any snapshot will do when `refs/main` is missing or points at a pruned one.
        let sha = [revision, named].compactMap { $0 }.first(where: all.contains) ?? (revision == nil ? cachedRevision(repo) : nil)
        guard let sha else {
            throw HubError(message: "\(repo) isn't in your Hugging Face cache", status: 404, code: "RevisionNotFound")
        }
        let readme = try? String(contentsOf: snapshot(repo, sha).appending(path: "README.md"), encoding: .utf8)
        return RepoInfo(sha: sha, gated: false, languages: readme.map(cardLanguages) ?? [])
    }

    func listRepoFiles(repo: String, revision: String, folder: String?) async throws -> [HubFile] {
        let root = snapshot(repo, revision)
        let prefix = folder.map { "\($0)/" } ?? ""
        let paths = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
        var files: [HubFile] = []
        for path in paths where path.hasPrefix(prefix) {
            let blob = root.appending(path: path).resolvingSymlinksInPath()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: blob.path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else { continue }
            let name = blob.lastPathComponent
            files.append(HubFile(
                repo: repo, revision: revision, path: path, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                sha256: name.matches("^[0-9a-f]{64}$") ? name : nil, gitOid: name.matches("^[0-9a-f]{40}$") ? name : ""
            ))
        }
        return files.sorted { $0.path < $1.path }
    }

    func readRepoFile(repo: String, revision: String, path: String) async throws -> String {
        try String(contentsOf: snapshot(repo, revision).appending(path: path), encoding: .utf8)
    }

    private func folder(_ repo: String) -> URL {
        cache.directory.appending(path: "models--\(repo.replacingOccurrences(of: "/", with: "--"))", directoryHint: .isDirectory)
    }

    private func snapshot(_ repo: String, _ sha: String) -> URL {
        folder(repo).appending(path: "snapshots/\(sha)", directoryHint: .isDirectory)
    }

    private func snapshots(_ repo: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder(repo).appending(path: "snapshots").path)) ?? [])
            .filter { $0.matches("^[0-9a-f]{40}$") }
    }
}

/// The `language` list of a model card's YAML front matter, like the Hub's info call reports it: a scalar,
/// a block list or a flow list, each item optionally quoted.
func cardLanguages(_ readme: String) -> [String] {
    let lines = readme.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    guard lines.first?.trimmed == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmed == "---" }) else { return [] }
    let front = lines[1..<end]
    guard let key = front.firstIndex(where: { $0.hasPrefix("language:") }) else { return [] }
    let unquote = { (item: String) in item.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    let inline = String(front[key].dropFirst("language:".count)).trimmed
    if inline.hasPrefix("[") {
        return inline.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
    }
    if !inline.isEmpty { return [unquote(inline)] }
    return front[(key + 1)...].prefix { $0.trimmed.hasPrefix("- ") }.map { unquote(String($0.trimmed.dropFirst(2))) }
}
