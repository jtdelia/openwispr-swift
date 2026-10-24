import Foundation
import Synchronization
import Testing
@testable import OpenWisprCore

private let whisperKit = "argmaxinc/whisperkit-coreml@0f63a7800b00dd0226abd051b906c246e1907482"
private let whisperSmall = "openai/whisper-small@973afd24965f72e36ca33b3055d56a652f456b4d"
private let qwen = "mlx-community/Qwen3-4B-Instruct-2507-4bit@50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
private let qwenId = "qwen3-4b-instruct-2507"
private let weights = Data(repeating: 7, count: 5000)
private let gb: Int64 = 1_000_000_000

private let qwenRepo: FakeRepo = [
    (".gitattributes", text("*.safetensors filter=lfs")),
    ("README.md", text("# Qwen")),
    ("config.json", text(#"{"model_type":"qwen3"}"#)),
    ("model.safetensors", FakeFile(content: weights, lfs: true)),
]

private let whisperSmallRepos: [String: FakeRepo] = [
    whisperKit: [("openai_whisper-small_216MB/config.json", text(#"{"d_model":768}"#))],
    whisperSmall: [("tokenizer.json", text(#"{"model":{}}"#)), ("tokenizer_config.json", text("{}"))],
]

private func weightRequests(_ hub: FakeHub) -> [String?] {
    hub.requests.filter { $0.url.hasSuffix("/model.safetensors") }.map(\.range)
}

private func isWeights(_ path: String) -> Bool { path.hasSuffix("/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/model.safetensors") }

private func droppedAfter(_ bytes: Int) -> FakeResponse { FakeResponse(chunks: [weights.prefix(bytes)], failure: Dropped()) }

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@MainActor
@Suite("Model downloads")
struct ModelDownloadTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    @Test func `lists files from Hugging Face at the pinned revision and installs them in the model folder`() async throws {
        let hub = FakeHub([
            whisperKit: [
                ("README.md", text("# WhisperKit")),
                ("openai_whisper-small_216MB/config.json", text(#"{"d_model":768}"#)),
                ("openai_whisper-small_216MB/AudioEncoder.mlmodelc/model.mil", text("program(1.0)")),
                ("openai_whisper-small_216MB/AudioEncoder.mlmodelc/weights/weight.bin", FakeFile(content: weights, lfs: true)),
                ("openai_whisper-tiny/config.json", text(#"{"d_model":384}"#)),
            ],
            whisperSmall: [
                ("README.md", text("# Whisper")),
                ("model.safetensors", FakeFile(content: Data(count: 100), lfs: true)),
                ("tokenizer.json", text(#"{"model":{}}"#)),
                ("tokenizer_config.json", text("{}")),
            ],
        ])
        let models = await makeModels(hub, directory: directory)

        try await models.download("whisper-small")

        let listings = hub.requests.filter { $0.url.contains("/tree/") }.map(\.url)
        #expect(listings.first == "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-small_216MB?recursive=true")
        #expect(listings.contains("https://huggingface.co/api/models/openai/whisper-small/tree/973afd24965f72e36ca33b3055d56a652f456b4d?recursive=true"))
        #expect(hub.requests.filter { $0.url.contains("/resolve/") }.map(\.url).sorted() == [
            "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-small_216MB/AudioEncoder.mlmodelc/model.mil",
            "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-small_216MB/AudioEncoder.mlmodelc/weights/weight.bin",
            "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-small_216MB/config.json",
            "https://huggingface.co/openai/whisper-small/resolve/973afd24965f72e36ca33b3055d56a652f456b4d/tokenizer.json",
            "https://huggingface.co/openai/whisper-small/resolve/973afd24965f72e36ca33b3055d56a652f456b4d/tokenizer_config.json",
        ])

        let folder = directory.appending(path: "whisper-small")
        #expect(try String(contentsOf: folder.appending(path: "config.json"), encoding: .utf8) == #"{"d_model":768}"#)
        #expect(try Data(contentsOf: folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin")) == weights)
        #expect(try String(contentsOf: folder.appending(path: "tokenizer.json"), encoding: .utf8) == #"{"model":{}}"#)
        #expect(!exists(folder.appending(path: "README.md")))

        #expect(try await status(models, "whisper-small").state == .installed(sizeBytes: 15 + 12 + 5000 + 12 + 2))
        let manifest = try #require(readJson(folder.appending(path: "manifest.json"), as: ModelManifest.self))
        #expect(manifest.entry.id == "whisper-small" && manifest.entry.engine == .whisperKit && manifest.entry.task == .speechToText)
        #expect(!manifest.userAdded)
        #expect(manifest.files.contains(ManifestFile(
            file: HubFile(
                repo: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482",
                path: "openai_whisper-small_216MB/AudioEncoder.mlmodelc/weights/weight.bin", size: 5000,
                sha256: sha256Hex(weights), gitOid: gitBlobSha1(weights)
            ),
            localPath: "AudioEncoder.mlmodelc/weights/weight.bin"
        )))
    }
}

@MainActor
@Suite("Verifying downloads")
struct VerifyingDownloadTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    func corrupt(_ target: String) -> FakeHub {
        let size = qwenRepo.first { $0.path == target }!.file.content.count
        return FakeHub([qwen: qwenRepo]) { path, _ in path.hasSuffix("/\(target)") && path.contains("/resolve/") ? .body(Data(repeating: 1, count: size)) : nil }
    }

    @Test func `discards a file whose SHA-256 differs from the published one and reports it`() async throws {
        let models = await makeModels(corrupt("model.safetensors"), directory: directory)
        let message = "model.safetensors didn't match its published SHA-256, so it was discarded"

        let error = await #expect(throws: AppError.self) { try await models.download(qwenId) }
        #expect(error?.message == message)

        let folder = directory.appending(path: qwenId)
        #expect(!exists(folder.appending(path: "model.safetensors")))
        #expect(!exists(folder.appending(path: "model.safetensors.part")))
        #expect(try await status(models, qwenId).state == .paused(bytesDone: 22, totalBytes: 5022, error: message))
    }

    @Test func `checks small files without a SHA-256 against their git blob hash`() async throws {
        let models = await makeModels(corrupt("config.json"), directory: directory)
        let error = await #expect(throws: AppError.self) { try await models.download(qwenId) }
        #expect(error?.message == "config.json didn't match its published Git hash, so it was discarded")
        #expect(!exists(directory.appending(path: "\(qwenId)/config.json")))
    }

    @Test func `stops a download that runs past the published size instead of filling the disk`() async throws {
        let hub = FakeHub([qwen: qwenRepo]) { path, _ in isWeights(path) ? FakeResponse(endless: Data(count: 1000)) : nil }
        let models = await makeModels(hub, directory: directory)

        let error = await #expect(throws: (any Error).self) { try await models.download(qwenId) }
        #expect(error.map(errorMessage) == "model.safetensors is larger than Hugging Face lists it, so it was discarded")
        #expect(weightRequests(hub) == [nil])
        guard case let .paused(bytesDone, _, _) = try await status(models, qwenId).state else {
            Issue.record("not paused")
            return
        }
        #expect(bytesDone == 22)
    }
}

@MainActor
@Suite("Cancelling, removing and disk usage")
struct CancellingDownloadTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    @Test func `cancels a running download and discards what it fetched`() async throws {
        let hub = FakeHub([qwen: qwenRepo]) { path, _ in isWeights(path) ? FakeResponse(chunks: [weights.prefix(1000)], hangs: true) : nil }
        let models = await makeModels(hub, directory: directory)
        let download = Task { try await models.download(qwenId) }
        try await eventually {
            guard case let .downloading(bytesDone, totalBytes, _) = try await status(models, qwenId).state else { return false }
            return bytesDone == 1022 && totalBytes == 5022
        }
        #expect(models.library.diskUsageBytes > 1022)

        try await models.cancelDownload(qwenId)

        try await download.value
        #expect(try await status(models, qwenId).state == .notDownloaded)
        #expect(!exists(directory.appending(path: qwenId)))
        #expect(models.library.diskUsageBytes == 0)
    }

    @Test func `removes an installed model, reporting the space freed, and totals disk usage across models`() async throws {
        var repos = whisperSmallRepos
        repos[qwen] = qwenRepo
        let models = await makeModels(FakeHub(repos), directory: directory)
        try await models.download(qwenId)
        try await models.download("whisper-small")
        let qwenManifest = Int64(try Data(contentsOf: directory.appending(path: "\(qwenId)/manifest.json")).count)
        let whisperManifest = Int64(try Data(contentsOf: directory.appending(path: "whisper-small/manifest.json")).count)
        await models.refreshLibrary()
        #expect(models.library.diskUsageBytes == 5022 + qwenManifest + 29 + whisperManifest)

        #expect(try await models.removeModel(qwenId) == 5022 + qwenManifest)

        #expect(try await status(models, qwenId).state == .notDownloaded)
        #expect(try await status(models, "whisper-small").state.isInstalled)
        #expect(models.library.diskUsageBytes == 29 + whisperManifest)
    }

    @Test func `unloads a removed model once requests using it finish, so a reinstall loads its new files`() async throws {
        let gate = Gate()
        var script = FakeEngines.Script()
        script.loadGate = gate
        let engines = FakeEngines(script)
        let models = await makeModels(FakeHub(whisperSmallRepos), engines: engines, directory: directory)
        try await models.download("whisper-small")
        await eventually { await gate.waiting == 1 }

        let removing = Task { try await models.removeModel("whisper-small") }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!engines.calls.contains(.unload(["whisper-small"])))
        #expect(exists(directory.appending(path: "whisper-small/config.json")))

        await gate.release()
        _ = try await removing.value

        #expect(engines.calls.last == .unload(["whisper-small"]))
        #expect(!exists(directory.appending(path: "whisper-small")))
    }
}

@MainActor
@Suite("Using a downloaded model")
struct UsingDownloadedModelTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    @Test func `makes a speech-to-text model selectable once installed, and loads it right away so its first dictation is quick`() async throws {
        let engines = FakeEngines()
        let settings = SettingsBox()
        settings.settings.speechToText = .builtIn(modelId: "whisper-small")
        settings.settings.language = "fr"
        let models = await makeModels(FakeHub(whisperSmallRepos), engines: engines, settings: settings, directory: directory)
        #expect(models.availability(.speechToText) != .available)

        try await models.download("whisper-small")

        #expect(models.availability(.speechToText) == .available)
        await eventually { engines.calls == [.load([ModelRef(role: .speechToText, id: "whisper-small", language: "fr")])] }
    }

    @Test func `does not load a downloaded chat model until it is used, since it would hold its memory`() async throws {
        let engines = FakeEngines()
        try await makeModels(FakeHub([qwen: qwenRepo]), engines: engines, directory: directory).download(qwenId)
        try await Task.sleep(for: .milliseconds(20))
        #expect(engines.calls.isEmpty)
    }
}

@MainActor
@Suite("Recommended models")
struct RecommendedModelTests {
    @Test func `lists speech-to-text, chat and vision models, flagging those needing over 60% of memory`() async throws {
        let models = await makeModels(directory: try temporaryDirectory(), physicalMemoryBytes: 8 * gb)
        let library = models.library
        #expect(Set(library.models.map(\.model.task)) == [.speechToText, .chat, .vision])
        #expect(library.models.allSatisfy { $0.recommended && $0.state == .notDownloaded })
        #expect(library.models.filter(\.oversized).map(\.model.id) == ["qwen3.5-9b", "gemma-4-e4b"])
        #expect(library.physicalMemoryBytes == 8 * gb)
        #expect(library.diskUsageBytes == 0)
    }
}

@MainActor
@Suite("Resuming downloads")
struct ResumingDownloadTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    @Test func `keeps the previous hashes until stale files from an update have been removed`() async throws {
        let repo = "example/updating-model"
        let hub = FakeHub([
            "\(repo)@old-revision": [("weights.bin", text("old!"))],
            "\(repo)@new-revision": [("weights.bin", text("new!"))],
        ])
        let gate = Gate()
        let released = Mutex<[String]>([])
        let releasing = LockedFlag()
        let downloads = ModelDownloads(directory: directory, http: hub, retryDelay: .zero, onChange: {}, release: { id in
            released.withLock { $0.append(id) }
            if releasing.set() { await gate.wait() }
        })
        func entry(_ revision: String) -> ModelEntry {
            ModelEntry(
                id: "updating-model", name: "Updating model", task: .chat, engine: .mlx, sources: [ModelSource(repo: repo, revision: revision)],
                sizeBytes: 4, memoryBytes: 4, speed: .fast, languages: "English", languageCodes: ["en"]
            )
        }
        _ = releasing.set()
        try await downloads.start(entry("old-revision"), userAdded: true)

        let update = Task { try await downloads.start(entry("new-revision"), userAdded: true) }
        await eventually { await gate.waiting == 1 }
        #expect(released.withLock { $0 } == ["updating-model"])
        let manifestURL = directory.appending(path: "updating-model/manifest.json")
        let pending = try #require(readJson(manifestURL, as: ModelManifest.self))
        #expect(!pending.installed)
        #expect(pending.files.first?.file.revision == "old-revision")

        await gate.release()
        try await update.value
        #expect(try String(contentsOf: directory.appending(path: "updating-model/weights.bin"), encoding: .utf8) == "new!")
        let installed = try #require(readJson(manifestURL, as: ModelManifest.self))
        #expect(installed.installed)
        #expect(installed.files.first?.file.revision == "new-revision")
    }

    @Test func `picks up where a dropped connection stopped with a range request`() async throws {
        let dropped = LockedFlag()
        let hub = FakeHub([qwen: qwenRepo]) { path, _ in isWeights(path) && !dropped.set() ? droppedAfter(2000) : nil }
        let models = await makeModels(hub, directory: directory)

        try await models.download(qwenId)

        #expect(weightRequests(hub) == [nil, "bytes=2000-"])
        #expect(try Data(contentsOf: directory.appending(path: "\(qwenId)/model.safetensors")) == weights)
        #expect(try await status(models, qwenId).state == .installed(sizeBytes: 22 + 5000))
    }

    @Test func `keeps the partial file when the network stays down, and resumes it after a restart`() async throws {
        let dropped = LockedFlag()
        let offline = FakeHub([qwen: qwenRepo]) { path, _ in
            guard isWeights(path) else { return nil }
            if dropped.set() { throw Dropped(message: "fetch failed") }
            return droppedAfter(2000)
        }
        let first = await makeModels(offline, directory: directory)
        await #expect(throws: Dropped.self) { try await first.download(qwenId) }
        #expect(try await status(first, qwenId).state == .paused(bytesDone: 22 + 2000, totalBytes: 22 + 5000, error: "fetch failed"))

        let online = FakeHub([qwen: qwenRepo])
        let afterRestart = await makeModels(online, directory: directory)
        guard case let .paused(bytesDone, _, _) = try await status(afterRestart, qwenId).state else {
            Issue.record("not paused")
            return
        }
        #expect(bytesDone == 2022)
        try await afterRestart.download(qwenId)

        #expect(weightRequests(online) == ["bytes=2000-"])
        #expect(!online.requests.contains { $0.url.hasSuffix("/config.json") })
        #expect(try Data(contentsOf: directory.appending(path: "\(qwenId)/model.safetensors")) == weights)
        #expect(try await status(afterRestart, qwenId).state.isInstalled)
    }

    @Test func `starts the file over when the server ignores the range`() async throws {
        let dropped = LockedFlag()
        let ranges = Mutex<[String?]>([])
        let hub = FakeHub([qwen: qwenRepo]) { path, request in
            guard isWeights(path) else { return nil }
            if !dropped.set() { return droppedAfter(2000) }
            ranges.withLock { $0.append(request.range) }
            return .body(weights)
        }

        try await makeModels(hub, directory: directory).download(qwenId)

        #expect(ranges.withLock { $0 } == ["bytes=2000-"])
        #expect(try Data(contentsOf: directory.appending(path: "\(qwenId)/model.safetensors")) == weights)
    }
}
