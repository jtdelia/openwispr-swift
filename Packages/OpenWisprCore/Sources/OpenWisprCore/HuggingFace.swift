import Foundation

let hubBase = "https://huggingface.co"
let hubUserAgent = "OpenWispr"

/// A file in a Hugging Face repo at a pinned commit.
public struct HubFile: Sendable, Equatable, Codable {
    public var repo: String
    public var revision: String
    public var path: String
    public var size: Int64
    /// Published only for files stored in Git LFS.
    public var sha256: String?
    /// Git blob SHA-1, `sha1("blob <size>\0" + bytes)`, published for every file.
    public var gitOid: String

    public init(repo: String, revision: String, path: String, size: Int64, sha256: String?, gitOid: String) {
        self.repo = repo
        self.revision = revision
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.gitOid = gitOid
    }
}

/// What the info call says about a repo at a revision.
public struct RepoInfo: Sendable, Equatable {
    /// The commit to pin.
    public var sha: String
    /// Gated repos need an account their owner approved, even to download.
    public var gated: Bool
    /// ISO codes from the model card, when it lists them.
    public var languages: [String]
}

public struct HubError: Error, Sendable, Equatable, LocalizedError {
    public let message: String
    public let status: Int
    /// Hugging Face's `x-error-code`, like `GatedRepo` or `EntryNotFound`.
    public let code: String?

    public var errorDescription: String? { message }

    /// Rate limits and server errors may pass; anything else will fail the same way again.
    public var retryable: Bool { status == 429 || status >= 500 }
}

public struct HuggingFace: Sendable {
    private let http: any HTTPClient

    public init(http: any HTTPClient) { self.http = http }

    private func get(_ url: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: url) else { throw AppError("Invalid Hugging Face URL \(url)") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(hubUserAgent, forHTTPHeaderField: "User-Agent")
        return try await http.data(for: request)
    }

    /// `revision` is a branch, tag or sha; without it, the head of the default branch.
    public func repoInfo(_ repo: String, revision: String? = nil) async throws -> RepoInfo {
        let suffix = revision.map { "/revision/\(encodeComponent($0))" } ?? ""
        let (data, response) = try await get("\(hubBase)/api/models/\(repo)\(suffix)")
        guard (200..<300).contains(response.statusCode) else { throw hubError(response, repo: repo) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let sha = json["sha"] as? String else { throw AppError("Hugging Face sent no commit for \(repo)") }
        let gated = (json["gated"] as? String).map { !$0.isEmpty } ?? (json["gated"] as? Bool ?? false)
        let language = (json["cardData"] as? [String: Any])?["language"]
        let languages = (language as? String).map { [$0] } ?? (language as? [String] ?? [])
        return RepoInfo(sha: sha, gated: gated, languages: languages)
    }

    /// A small file's text, like `config.json`; never use it for weights.
    public func readRepoFile(repo: String, revision: String, path: String) async throws -> String {
        let (data, response) = try await get(resolveUrl(repo: repo, revision: revision, path: path))
        guard (200..<300).contains(response.statusCode) else { throw hubError(response, repo: repo, path: path) }
        return String(decoding: data, as: UTF8.self)
    }

    private struct TreeEntry: Decodable {
        struct Lfs: Decodable {
            var oid: String
            var size: Int64
        }

        var type: String
        var path: String
        var size: Int64?
        var oid: String
        var lfs: Lfs?
    }

    /// Every file in `repo` at `revision`, or only those under `folder`, following pagination.
    public func listRepoFiles(repo: String, revision: String, folder: String? = nil) async throws -> [HubFile] {
        var files: [HubFile] = []
        var next: String? = "\(hubBase)/api/models/\(repo)/tree/\(revision)\(folder.map { "/\(encodePath($0))" } ?? "")?recursive=true"
        while let url = next {
            try Task.checkCancellation()
            let (data, response) = try await get(url)
            guard (200..<300).contains(response.statusCode) else { throw hubError(response, repo: repo) }
            for entry in try JSONDecoder().decode([TreeEntry].self, from: data) where entry.type == "file" {
                files.append(HubFile(
                    repo: repo, revision: revision, path: entry.path, size: entry.lfs?.size ?? entry.size ?? 0,
                    sha256: entry.lfs?.oid, gitOid: entry.oid
                ))
            }
            next = response.value(forHTTPHeaderField: "Link")?.firstMatch(#"<([^>]+)>;\s*rel="next""#)?[1] ?? nil
        }
        return files
    }
}

/// Redirects to a signed CDN URL that expires, so request this again for every (re)start.
public func resolveUrl(repo: String, revision: String, path: String) -> String {
    "\(hubBase)/\(repo)/resolve/\(revision)/\(encodePath(path))"
}

func hubError(_ response: HTTPURLResponse, repo: String, path: String? = nil) -> HubError {
    let code = response.value(forHTTPHeaderField: "x-error-code")
    let status = response.statusCode
    let message: String = switch code {
    case "GatedRepo": "\(repo) is gated: its owner must grant access first"
    case "RevisionNotFound": "\(repo) has no such revision"
    case "EntryNotFound": "\(path ?? "A file") is missing from \(repo)"
    default:
        // Anonymously, a private repo answers exactly like a missing one.
        if status == 401 {
            "\(repo) was not found or is private"
        } else if status == 429 {
            "Hugging Face is rate limiting downloads; try again shortly"
        } else {
            "Hugging Face answered \(status)\(path.map { " for \($0)" } ?? "")"
        }
    }
    return HubError(message: message, status: status, code: code)
}

private let uriComponentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

/// Like `encodeURIComponent`.
func encodeComponent(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: uriComponentCharacters) ?? text
}

func encodePath(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false).map { encodeComponent(String($0)) }.joined(separator: "/")
}
