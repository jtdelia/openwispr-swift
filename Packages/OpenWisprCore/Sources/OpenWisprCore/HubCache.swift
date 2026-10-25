import Foundation

/// The Hugging Face hub cache other tools (`huggingface_hub`, mlx-lm, WhisperKit) download into. Its
/// `models--<org>--<name>/blobs` folders name each file by its etag: the SHA-256 for Git LFS files and the
/// Git blob SHA-1 for the rest, so a file is found by the hashes a `HubFile` publishes, at any revision.
public struct HubCache: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Where `huggingface_hub` puts it: `HF_HUB_CACHE`, else `HF_HOME/hub`, else `~/.cache/huggingface/hub`.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> HubCache {
        let expand = { (path: String) in URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
        if let cache = environment["HF_HUB_CACHE"], !cache.isEmpty { return HubCache(directory: expand(cache)) }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty { return HubCache(directory: expand(hfHome).appending(path: "hub")) }
        return HubCache(directory: home.appending(path: ".cache/huggingface/hub", directoryHint: .isDirectory))
    }

    /// Cached copies of `file` of the right size, from its own repo first and then any other, since blobs
    /// are named by content. Newer `huggingface_hub` versions link blobs into a shared store, so these are
    /// the files the links point to. The caller still verifies their hashes.
    func blobs(for file: HubFile) -> [URL] {
        let name = file.sha256 ?? file.gitOid
        guard name.matches("^[0-9a-f]{40,64}$") else { return [] }
        let own = "models--\(file.repo.replacingOccurrences(of: "/", with: "--"))"
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("models--") && $0 != own }
            .sorted()
        return ([own] + others)
            .map { directory.appending(path: "\($0)/blobs/\(name)").resolvingSymlinksInPath() }
            .filter { sizeOf($0) == file.size }
    }
}
