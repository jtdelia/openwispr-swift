import Foundation
import Testing
@testable import OpenWisprCore

private let sha = String(repeating: "a", count: 40)
private let older = String(repeating: "c", count: 40)
private let weights = Data(repeating: 7, count: 5000)
private let whisperConfig = #"{"model_type":"whisper","vocab_size":51864,"d_model":768,"num_mel_bins":80,"torch_dtype":"float32"}"#
private let generation = #"{"eos_token_id":50256,"decoder_start_token_id":50257,"prev_sot_token_id":50360,"no_timestamps_token_id":50362}"#

private let whisperRepo: FakeRepo = [
    ("README.md", text("---\nlanguage:\n- en\npipeline_tag: automatic-speech-recognition\n---\n# Whisper")),
    ("config.json", text(whisperConfig)),
    ("generation_config.json", text(generation)),
    ("model.safetensors", FakeFile(content: weights, lfs: true)),
    ("pytorch_model.bin", FakeFile(content: Data(repeating: 8, count: 5000), lfs: true)),
    ("tokenizer.json", text(#"{"model":{}}"#)),
    ("tokenizer_config.json", text("{}")),
]

private let mlxRepo: FakeRepo = [
    ("config.json", text(#"{"model_type":"qwen3","quantization":{"group_size":64,"bits":4}}"#)),
    ("model.safetensors", FakeFile(content: weights, lfs: true)),
    ("tokenizer.json", text(#"{"model":{}}"#)),
    ("tokenizer_config.json", text("{}")),
]

/// Lays `files` out the way `huggingface_hub` does: blobs named by etag, linked from `snapshots/<revision>`.
private func cacheRepo(_ cache: HubCache, _ repo: String, revision: String = sha, _ files: FakeRepo, main: Bool = true) throws {
    let folder = cache.directory.appending(path: "models--\(repo.replacingOccurrences(of: "/", with: "--"))")
    let blobs = folder.appending(path: "blobs")
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    for (path, file) in files {
        let name = file.lfs ? sha256Hex(file.content) : gitBlobSha1(file.content)
        try file.content.write(to: blobs.appending(path: name))
        let link = folder.appending(path: "snapshots/\(revision)/\(path)")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let depth = path.split(separator: "/").count + 1
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: String(repeating: "../", count: depth) + "blobs/\(name)"
        )
    }
    if main {
        try FileManager.default.createDirectory(at: folder.appending(path: "refs"), withIntermediateDirectories: true)
        try Data(revision.utf8).write(to: folder.appending(path: "refs/main"))
    }
}

@MainActor
@Suite("Finding models in the Hugging Face cache")
struct CachedModelsTests {
    let directory: URL
    let cache: HubCache

    init() throws {
        directory = try temporaryDirectory()
        cache = HubCache(directory: try temporaryDirectory())
    }

    @Test func `lists the cached models OpenWispr can run, without the network`() async throws {
        try cacheRepo(cache, "openai/whisper-small.en", whisperRepo)
        try cacheRepo(cache, "mlx-community/Qwen3-1.7B-4bit", mlxRepo)
        try cacheRepo(cache, "openai/whisper-tiny", [("model.safetensors", FakeFile(content: weights, lfs: true))])
        try cacheRepo(cache, "unsloth/gemma-4-E2B-it-GGUF", [("gemma.gguf", FakeFile(content: weights, lfs: true))])
        try cacheRepo(cache, "mlx-community/Qwen3-4B-Instruct-2507-4bit", mlxRepo)
        try FileManager.default.createDirectory(at: cache.directory.appending(path: "models--someone--only-refs/refs"), withIntermediateDirectories: true)
        let offline = FakeHub { _, _ in throw Dropped(message: "offline") }

        let models = await makeModels(offline, directory: directory, hubCache: cache)
        await models.refreshCachedModels()

        #expect(models.cachedModels.map(\.id) == ["hf-mlx-community--Qwen3-1.7B-4bit", "hf-openai--whisper-small.en"])
        let whisper = try #require(models.cachedModels.last)
        #expect(whisper.summary == "Whisper on MLX, float32 weights" && !whisper.oversized)
        #expect(whisper.model.engine == .mlxWhisper && whisper.model.languageCodes == ["en"])
        #expect(whisper.model.sources == [ModelSource(
            repo: "openai/whisper-small.en", revision: sha,
            files: ["config.json", "generation_config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]
        )])
        #expect(offline.requests.isEmpty)
    }

    @Test func `adds a cached model by cloning its files, then stops offering it`() async throws {
        try cacheRepo(cache, "openai/whisper-small.en", whisperRepo)
        let hub = FakeHub(["openai/whisper-small.en@\(sha)": whisperRepo])
        let models = await makeModels(hub, directory: directory, hubCache: cache)
        await models.refreshCachedModels()
        let found = try #require(models.cachedModels.first)

        try await models.addModel(found.model)

        #expect(!hub.requests.contains { $0.url.contains("/resolve/") })
        #expect(try Data(contentsOf: directory.appending(path: "\(found.id)/model.safetensors")) == weights)
        let added = try await status(models, found.id)
        #expect(added.userAdded && added.state.isInstalled)
        #expect(models.cachedModels.isEmpty)
    }

    @Test func `reads the revision refs-main points at, and a new model once the cache is scanned again`() async throws {
        try cacheRepo(cache, "openai/whisper-small.en", revision: older, whisperRepo.filter { $0.path != "tokenizer.json" }, main: false)
        try cacheRepo(cache, "openai/whisper-small.en", whisperRepo)
        let models = await makeModels(directory: directory, hubCache: cache)
        await models.refreshCachedModels()
        #expect(models.cachedModels.map { $0.model.sources[0].revision } == [sha])

        try cacheRepo(cache, "mlx-community/Qwen3-1.7B-4bit", mlxRepo)
        await models.refreshCachedModels()
        #expect(models.cachedModels.count == 2)
    }

    @Test func `offers each WhisperKit folder in the cache whose tokenizer is cached too, except the Recommended one`() async throws {
        let mlmodel = text("program(1.0)")
        let folder = { (name: String) -> FakeRepo in
            ["AudioEncoder", "MelSpectrogram", "TextDecoder"].map { ("\(name)/\($0).mlmodelc/coremldata.bin", mlmodel) }
                + [("\(name)/config.json", text(#"{"_name_or_path":"openai/whisper-small","vocab_size":51865,"d_model":768}"#))]
        }
        try cacheRepo(cache, "argmaxinc/whisperkit-coreml", folder("openai_whisper-small_216MB") + folder("openai_whisper-small_hq"))
        // Cached at a pinned commit, so it has a snapshot but no refs/main.
        try cacheRepo(cache, "openai/whisper-small", [("tokenizer.json", text(#"{"model":{}}"#)), ("tokenizer_config.json", text("{}"))], main: false)

        let found = await discoverCachedModels(cache)

        #expect(found.map(\.model.name) == ["openai_whisper-small_hq"])
    }

    @Test func `skips a snapshot whose files aren't linked to blobs, since adding it would download them`() async throws {
        let snapshot = cache.directory.appending(path: "models--openai--whisper-small.en/snapshots/\(sha)")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for (path, file) in whisperRepo { try file.content.write(to: snapshot.appending(path: path)) }

        let found = await discoverCachedModels(cache)

        #expect(found.isEmpty)
    }

    @Test func `reads the languages of a model card too large to read whole`() async throws {
        let card = "---\nlanguage:\n- en\n- fr\n---\n" + String(repeating: "é", count: 200_000)
        try cacheRepo(cache, "openai/whisper-small.en", [("README.md", text(card))])

        let info = try await CachedHub(cache: cache).repoInfo("openai/whisper-small.en", revision: nil)

        #expect(info.languages == ["en", "fr"])
    }

    @Test func `reads a model card’s languages from its front matter`() {
        #expect(cardLanguages("---\nlanguage:\n- en\n- fr\nlicense: mit\n---\n# Model") == ["en", "fr"])
        #expect(cardLanguages("---\nlanguage: de\n---\n") == ["de"])
        #expect(cardLanguages("---\nlanguage: [en, 'fr', \"de\"]\n---\n") == ["en", "fr", "de"])
        #expect(cardLanguages("---\r\nlanguage:\r\n- \"en\"\r\n- fr\r\n---\r\n") == ["en", "fr"])
        #expect(cardLanguages("# No front matter\nlanguage: en") == [])
    }
}
