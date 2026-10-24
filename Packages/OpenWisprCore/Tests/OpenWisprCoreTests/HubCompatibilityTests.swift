import Foundation
import Testing
@testable import OpenWisprCore

private let sha = String(repeating: "a", count: 40)
private let tokenizerSha = String(repeating: "b", count: 40)
private let weights = Data(repeating: 7, count: 5000)
private let mlmodel = "program(1.0)"
private let mlxConfig = #"{"model_type":"qwen3_5","quantization":{"group_size":64,"bits":4},"vision_config":{}}"#

private func mlxRepo(config: String = mlxConfig) -> FakeRepo {
    [
        (".gitattributes", text("*.safetensors filter=lfs")),
        ("README.md", text("# Qwen3.5")),
        ("config.json", text(config)),
        ("model.safetensors", FakeFile(content: weights, lfs: true)),
        ("tokenizer.json", text(#"{"model":{}}"#)),
        ("tokenizer_config.json", text("{}")),
        ("chat_template.jinja", text("{%- if enable_thinking is false %}{%- endif %}")),
    ]
}

private func whisperFolder(_ folder: String, config: String, skip: [String] = []) -> FakeRepo {
    let files: FakeRepo = [
        ("AudioEncoder.mlmodelc/coremldata.bin", text(mlmodel)),
        ("AudioEncoder.mlmodelc/weights/weight.bin", FakeFile(content: weights, lfs: true)),
        ("MelSpectrogram.mlmodelc/coremldata.bin", text(mlmodel)),
        ("TextDecoder.mlmodelc/coremldata.bin", text(mlmodel)),
        ("config.json", text(config)),
        ("generation_config.json", text("{}")),
    ]
    return files.filter { file in !skip.contains { file.path.hasPrefix($0) } }.map { ("\(folder)/\($0.path)", $0.file) }
}

private let whisperTokenizerRepo: FakeRepo = [
    ("README.md", text("# Whisper")),
    ("model.safetensors", FakeFile(content: weights, lfs: true)),
    ("tokenizer.json", text(#"{"model":{}}"#)),
    ("tokenizer_config.json", text("{}")),
]

private let whisperSmallConfig = #"{"_name_or_path":"openai/whisper-small","vocab_size":51865,"d_model":768}"#

private func parakeetRepo(joint: String = "JointDecisionv3") -> FakeRepo {
    [
        ("README.md", text("# Parakeet")),
        ("config.json", text("{}")),
        ("Preprocessor.mlmodelc/coremldata.bin", text(mlmodel)),
        ("Encoder.mlmodelc/coremldata.bin", text(mlmodel)),
        ("Encoder.mlmodelc/weights/weight.bin", FakeFile(content: weights, lfs: true)),
        ("Encoder_v2.mlmodelc/coremldata.bin", text(mlmodel)),
        ("Decoder.mlmodelc/coremldata.bin", text(mlmodel)),
        ("\(joint).mlmodelc/coremldata.bin", text(mlmodel)),
        ("parakeet_vocab.json", text(#"{"0":"<unk>"}"#)),
    ]
}

private func compatible(_ check: RepoCheck) throws -> ModelEntry {
    guard case let .compatible(model, _, _) = check else {
        Issue.record("not compatible: \(check)")
        throw AppError("not compatible")
    }
    return model
}

@MainActor
@Suite("Rejecting repos OpenWispr can’t download or run")
struct RejectingRepoTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    @Test func `rejects a GGUF-only repo, which is for llama.cpp`() async {
        let hub = FakeHub(["Qwen/Qwen3-4B-GGUF@\(sha)": [
            ("README.md", text("# GGUF")),
            ("Qwen3-4B-Q4_K_M.gguf", FakeFile(content: weights, lfs: true)),
            ("Qwen3-4B-Q8_0.gguf", FakeFile(content: weights, lfs: true)),
        ]])
        let check = await makeModels(hub, directory: directory).checkRepo("Qwen/Qwen3-4B-GGUF")
        #expect(check == .rejected(
            reason: .ggufOnly,
            message: "Qwen/Qwen3-4B-GGUF only has GGUF weights, which are for llama.cpp. OpenWispr runs chat models with MLX: look for an MLX version, often from mlx-community"
        ))
    }

    @Test func `rejects a gated repo before downloading anything, since downloads are anonymous`() async {
        let hub = FakeHub(["meta-llama/Llama-3.2-1B@\(sha)": mlxRepo()], info: ["meta-llama/Llama-3.2-1B": FakeRepoInfo(gated: "manual")])
        let check = await makeModels(hub, directory: directory).checkRepo("https://huggingface.co/meta-llama/Llama-3.2-1B")
        #expect(check == .rejected(
            reason: .gated,
            message: "meta-llama/Llama-3.2-1B is gated: its owner approves each download, and OpenWispr downloads without a Hugging Face account"
        ))
        #expect(hub.downloadedPaths.isEmpty)
    }

    @Test func `reports a missing and a private repo with one reason, since Hugging Face answers both alike`() async {
        let check = await makeModels(FakeHub(), directory: directory).checkRepo("someone/not-a-model")
        #expect(check == .rejected(
            reason: .notFoundOrPrivate,
            message: "someone/not-a-model was not found or is private. Check the spelling; private repos can't be downloaded"
        ))
    }

    @Test func `rejects a revision the repo does not have`() async {
        let hub = FakeHub(["mlx-community/Qwen3.5-4B-4bit@\(sha)": mlxRepo()])
        let check = await makeModels(hub, directory: directory).checkRepo("https://huggingface.co/mlx-community/Qwen3.5-4B-4bit/tree/v9")
        #expect(check == .rejected(reason: .notFoundOrPrivate, message: "mlx-community/Qwen3.5-4B-4bit has no such revision"))
    }

    @Test func `says so when Hugging Face can’t be reached, rather than blaming the repo`() async {
        let offline = FakeHub { _, _ in throw Dropped(message: "fetch failed") }
        let check = await makeModels(offline, directory: directory).checkRepo("mlx-community/Qwen3.5-4B-4bit")
        #expect(check == .rejected(reason: .hubFailed, message: "Couldn't check the repo on Hugging Face: fetch failed"))
    }

    @Test func `points to the Recommended model when the repo is one`() async {
        let hub = FakeHub(["mlx-community/Qwen3-4B-Instruct-2507-4bit@\(sha)": mlxRepo(config: #"{"model_type":"qwen3","quantization":{"group_size":64,"bits":4}}"#)])
        let check = await makeModels(hub, directory: directory).checkRepo("mlx-community/Qwen3-4B-Instruct-2507-4bit")
        #expect(check == .rejected(
            reason: .alreadyListed,
            message: "mlx-community/Qwen3-4B-Instruct-2507-4bit is already in Recommended models as Qwen3 4B Instruct"
        ))
    }

    @Test(arguments: ["", "not a repo", "https://huggingface.co/datasets/someone/data", "https://example.com/a/b"])
    func `asks for a model id`(input: String) async {
        let check = await makeModels(FakeHub(), directory: directory).checkRepo(input)
        guard case .rejected(.invalidReference, _) = check else {
            Issue.record("\(check)")
            return
        }
    }
}

@MainActor
@Suite("Adding a compatible repo")
struct AddingRepoTests {
    let directory: URL
    let repo = "mlx-community/Qwen3.5-4B-4bit"
    let id = "hf-mlx-community--Qwen3.5-4B-4bit"
    let info = ["mlx-community/Qwen3.5-4B-4bit": FakeRepoInfo(languages: ["en", "zh", "fr"])]

    init() throws { directory = try temporaryDirectory() }

    /// Sends the first 2000 bytes of the weights, then the network goes down for good.
    func droppingHub() -> FakeHub {
        let dropped = LockedFlag()
        return FakeHub(["\(repo)@\(sha)": mlxRepo()], info: info) { path, _ in
            guard path.hasSuffix("/model.safetensors") else { return nil }
            if dropped.set() { throw Dropped(message: "fetch failed") }
            return FakeResponse(chunks: [weights.prefix(2000)], failure: Dropped())
        }
    }

    @Test func `downloads it like a Recommended model, resuming after a restart, then lists it as added by the user`() async throws {
        let first = await makeModels(droppingHub(), directory: directory)
        let model = try compatible(await first.checkRepo(repo))
        #expect(model.languages == "3 languages")

        await #expect(throws: (any Error).self) { try await first.addModel(model) }

        let online = FakeHub(["\(repo)@\(sha)": mlxRepo()], info: info)
        let afterRestart = await makeModels(online, directory: directory)
        let paused = try await status(afterRestart, id)
        #expect(paused.userAdded && !paused.recommended)
        guard case let .paused(bytesDone, _, _) = paused.state else {
            Issue.record("\(paused.state)")
            return
        }
        #expect(bytesDone == 85 + 2000)

        try await afterRestart.download(id)

        #expect(online.requests.filter { $0.url.hasSuffix("/model.safetensors") }.map(\.range) == ["bytes=2000-"])
        let installed = try await status(afterRestart, id)
        #expect(installed.userAdded && !installed.recommended)
        #expect(installed.model.name == "Qwen3.5-4B-4bit")
        #expect(installed.model.task == .chat && installed.model.engine == .mlx)
        #expect(installed.model.chatTemplateContext == ["enable_thinking": false])
        #expect(installed.state == .installed(sizeBytes: 5145))
        #expect(afterRestart.library.models.contains { $0.recommended })
    }

    @Test func `can be selected for its task, and removed once another model is selected`() async throws {
        let settings = SettingsBox()
        settings.settings.chat = .builtIn(modelId: id)
        let selecting = await makeModels(FakeHub(["\(repo)@\(sha)": mlxRepo()], info: info), settings: settings, directory: directory)
        try await selecting.addModel(try compatible(await selecting.checkRepo(repo)))

        #expect(selecting.availability(.chat) == .available)
        let refused = await #expect(throws: AppError.self) { _ = try await selecting.removeModel(id) }
        #expect(refused?.message == "Qwen3.5-4B-4bit is selected for chat. Choose another model in Settings before removing it")

        let other = await makeModels(directory: directory)
        #expect(try await other.removeModel(id) > 5145)
        await other.refreshLibrary()
        #expect(!other.library.models.contains { $0.model.id == id })
    }

    @Test func `replaces files that changed when added again at a newer revision, even when their size did not`() async throws {
        let newer = String(repeating: "c", count: 40)
        let newWeights = Data(repeating: 9, count: weights.count)
        let hub = FakeHub([
            "\(repo)@\(sha)": mlxRepo(),
            "\(repo)@\(newer)": mlxRepo().map { $0.path == "model.safetensors" ? ($0.path, FakeFile(content: newWeights, lfs: true)) : $0 },
        ])
        let models = await makeModels(hub, directory: directory)
        try await models.addModel(try compatible(await models.checkRepo(repo)))
        try await models.addModel(try compatible(await models.checkRepo("https://huggingface.co/\(repo)/tree/\(newer)")))

        #expect(try Data(contentsOf: directory.appending(path: "\(id)/model.safetensors")) == newWeights)
        #expect(hub.downloadedPaths.filter { $0 == "model.safetensors" }.count == 2)
        #expect(hub.downloadedPaths.filter { $0 == "tokenizer.json" }.count == 1)
    }
}

@MainActor
@Suite("Checking a WhisperKit repo")
struct WhisperKitRepoTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    @Test func `accepts a WhisperKit folder, taking its tokenizer from the matching OpenAI repo`() async throws {
        let hub = FakeHub([
            "argmaxinc/whisperkit-coreml@\(sha)": [("README.md", text("# WhisperKit")), ("config.json", text(#"{"device_support":[]}"#))]
                + whisperFolder("openai_whisper-small", config: whisperSmallConfig)
                + whisperFolder("openai_whisper-tiny", config: #"{"vocab_size":51865,"d_model":384}"#),
            "openai/whisper-small@\(tokenizerSha)": whisperTokenizerRepo,
        ])

        let check = await makeModels(hub, directory: directory)
            .checkRepo("https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small")

        let sizeBytes = Int64(3 * mlmodel.utf8.count + 5000 + whisperSmallConfig.utf8.count + 2 + 12 + 2)
        #expect(check == .compatible(
            model: ModelEntry(
                id: "hf-argmaxinc--whisperkit-coreml--openai_whisper-small", name: "openai_whisper-small", task: .speechToText, engine: .whisperKit,
                sources: [
                    ModelSource(repo: "argmaxinc/whisperkit-coreml", revision: sha, folder: "openai_whisper-small", files: [
                        "openai_whisper-small/AudioEncoder.mlmodelc/",
                        "openai_whisper-small/MelSpectrogram.mlmodelc/",
                        "openai_whisper-small/TextDecoder.mlmodelc/",
                        "openai_whisper-small/config.json",
                        "openai_whisper-small/generation_config.json",
                    ]),
                    ModelSource(repo: "openai/whisper-small", revision: tokenizerSha, files: ["tokenizer.json", "tokenizer_config.json"]),
                ],
                sizeBytes: sizeBytes, memoryBytes: Int64((Double(sizeBytes) * 1.7).rounded()), speed: .fastest,
                languages: "99 languages", languageCodes: nil
            ),
            summary: "WhisperKit (Core ML), tokenizer from openai/whisper-small",
            oversized: false
        ))
        #expect(hub.downloadedPaths == ["openai_whisper-small/config.json"])
    }

    @Test func `offers the model folders of a repo holding several, like WhisperKit’s`() async {
        let hub = FakeHub([
            "argmaxinc/whisperkit-coreml@\(sha)": [("config.json", text(#"{"device_support":[]}"#))]
                + whisperFolder("openai_whisper-small_216MB", config: whisperSmallConfig)
                + whisperFolder("openai_whisper-tiny", config: #"{"vocab_size":51865,"d_model":384}"#),
        ])
        let check = await makeModels(hub, directory: directory).checkRepo("argmaxinc/whisperkit-coreml")
        #expect(check == .severalModels(
            repo: "argmaxinc/whisperkit-coreml", revision: sha, folders: ["openai_whisper-small_216MB", "openai_whisper-tiny"],
            message: "argmaxinc/whisperkit-coreml holds 2 speech-to-text models. Choose one"
        ))
    }

    @Test func `recognizes an English-only Whisper from its vocabulary when its config names no OpenAI repo`() async throws {
        let hub = FakeHub([
            "someone/whisper-base-en-coreml@\(sha)": whisperFolder("base.en", config: #"{"_name_or_path":"./out","vocab_size":51864,"d_model":512}"#),
            "openai/whisper-base.en@\(tokenizerSha)": whisperTokenizerRepo,
        ])
        let check = await makeModels(hub, directory: directory).checkRepo("someone/whisper-base-en-coreml/tree/main/base.en")
        guard case let .compatible(model, summary, oversized) = check else {
            Issue.record("\(check)")
            return
        }
        #expect(!oversized)
        #expect(summary == "WhisperKit (Core ML), tokenizer from openai/whisper-base.en")
        #expect(model.languages == "English" && model.languageCodes == ["en"])
    }

    @Test func `rejects a WhisperKit folder missing one of its Core ML models`() async {
        let hub = FakeHub(["argmaxinc/whisperkit-coreml@\(sha)": whisperFolder("openai_whisper-small_216MB", config: whisperSmallConfig, skip: ["TextDecoder"])])
        let check = await makeModels(hub, directory: directory).checkRepo("argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small_216MB")
        #expect(check == .rejected(
            reason: .missingFiles,
            message: "argmaxinc/whisperkit-coreml/openai_whisper-small_216MB is missing TextDecoder.mlmodelc, which WhisperKit needs"
        ))
    }
}

@MainActor
@Suite("Checking a FluidAudio repo")
struct FluidAudioRepoTests {
    let directory: URL
    init() throws { directory = try temporaryDirectory() }

    @Test func `accepts the Parakeet TDT v3 layout FluidAudio loads, fetching only the files it reads`() async throws {
        let hub = FakeHub(
            ["someone/parakeet-tdt-0.6b-v3-coreml@\(sha)": parakeetRepo()],
            info: ["someone/parakeet-tdt-0.6b-v3-coreml": FakeRepoInfo(languages: ["en", "de", "fr"])]
        )
        let check = await makeModels(hub, directory: directory).checkRepo("someone/parakeet-tdt-0.6b-v3-coreml")
        let model = try compatible(check)
        let sizeBytes = Int64(4 * mlmodel.utf8.count + 5000 + 13)
        guard case let .compatible(_, summary, oversized) = check else { return }
        #expect(summary == "Parakeet TDT v3 (FluidAudio, Core ML)" && !oversized)
        #expect(model.id == "hf-someone--parakeet-tdt-0.6b-v3-coreml")
        #expect(model.name == "parakeet-tdt-0.6b-v3-coreml")
        #expect(model.task == .speechToText && model.engine == .fluidAudio)
        #expect(model.sources == [ModelSource(
            repo: "someone/parakeet-tdt-0.6b-v3-coreml", revision: sha,
            files: ["Decoder.mlmodelc/", "Encoder.mlmodelc/", "JointDecisionv3.mlmodelc/", "Preprocessor.mlmodelc/", "parakeet_vocab.json"]
        )])
        #expect(model.sizeBytes == sizeBytes)
        #expect(model.memoryBytes == Int64((Double(sizeBytes) * 1.7).rounded()))
        #expect(model.languages == "25 European languages")
        #expect(Set(["bg", "en", "uk"]).isSubset(of: model.languageCodes ?? []))
        #expect(hub.downloadedPaths.isEmpty)
    }

    @Test func `rejects an older Parakeet layout FluidAudio would load as the wrong version`() async {
        let hub = FakeHub(["FluidInference/parakeet-tdt-0.6b-v2-coreml@\(sha)": parakeetRepo(joint: "JointDecision")])
        let check = await makeModels(hub, directory: directory).checkRepo("FluidInference/parakeet-tdt-0.6b-v2-coreml")
        #expect(check == .rejected(
            reason: .missingFiles,
            message: "FluidInference/parakeet-tdt-0.6b-v2-coreml is missing JointDecisionv3.mlmodelc, which Parakeet TDT v3 needs"
        ))
    }
}

@MainActor
@Suite("Checking an MLX repo")
struct MlxRepoTests {
    let directory: URL
    let repo = "mlx-community/Qwen3.5-4B-4bit"
    init() throws { directory = try temporaryDirectory() }

    func without(_ paths: String...) -> FakeRepo { mlxRepo().filter { !paths.contains($0.path) } }

    @Test func `accepts quantized MLX weights with a supported model_type, reading only the small config files`() async throws {
        let hub = FakeHub(["\(repo)@\(sha)": mlxRepo()])
        let check = await makeModels(hub, directory: directory).checkRepo("https://huggingface.co/\(repo)")
        #expect(check == .compatible(
            model: ModelEntry(
                id: "hf-mlx-community--Qwen3.5-4B-4bit", name: "Qwen3.5-4B-4bit", task: .chat, engine: .mlx,
                sources: [ModelSource(
                    repo: repo, revision: sha,
                    files: ["chat_template.jinja", "config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]
                )],
                sizeBytes: 46 + 85 + 5000 + 12 + 2, memoryBytes: 6500, speed: .fastest,
                languages: "Languages not listed", languageCodes: nil, chatTemplateContext: ["enable_thinking": false]
            ),
            summary: "MLX qwen3_5, 4-bit",
            oversized: false
        ))
        #expect(!hub.downloadedPaths.contains("model.safetensors"))
    }

    @Test func `rejects a model_type the MLX engine has no architecture for`() async {
        let hub = FakeHub(["mlx-community/Qwen3.8-Flash-Next-4bit@\(sha)": mlxRepo(config: #"{"model_type":"qwen4_exp","quantization":{"group_size":32,"bits":4}}"#)])
        let check = await makeModels(hub, directory: directory).checkRepo("mlx-community/Qwen3.8-Flash-Next-4bit")
        #expect(check == .rejected(
            reason: .unsupportedArchitecture,
            message: "mlx-community/Qwen3.8-Flash-Next-4bit uses the qwen4_exp architecture, which OpenWispr's MLX engine doesn't support yet"
        ))
    }

    @Test(arguments: [
        (
            #"{"model_type":"qwen3","quantization_config":{"bits":4,"group_size":128,"quant_method":"awq"}}"#,
            "Qwen/Qwen3-4B-AWQ is quantized with awq, which MLX can't load. Look for an MLX version, often from mlx-community"
        ),
        (
            #"{"model_type":"qwen3"}"#,
            "Qwen/Qwen3-4B-AWQ has no MLX quantization config, so its weights aren't quantized for MLX. Look for a 4-bit MLX version, often from mlx-community"
        ),
    ])
    func `rejects safetensors not quantized for MLX`(config: String, message: String) async {
        let hub = FakeHub(["Qwen/Qwen3-4B-AWQ@\(sha)": mlxRepo(config: config)])
        #expect(await makeModels(hub, directory: directory).checkRepo("Qwen/Qwen3-4B-AWQ") == .rejected(reason: .notMlx, message: message))
    }

    @Test func `rejects MLX weights missing a file they need`() async {
        let cases: [(FakeRepo, String)] = [
            (without("config.json"), "config.json"),
            (without("tokenizer.json"), "tokenizer.json"),
            (
                without("model.safetensors") + [
                    ("model.safetensors.index.json", text("{}")),
                    ("model-00001-of-00003.safetensors", FakeFile(content: weights, lfs: true)),
                    ("model-00003-of-00003.safetensors", FakeFile(content: weights, lfs: true)),
                ],
                "model-00002-of-00003.safetensors"
            ),
            (
                without("model.safetensors") + [("model-00001-of-1000000000.safetensors", FakeFile(content: weights, lfs: true))],
                "most of the 1000000000 shards of model.safetensors"
            ),
        ]
        for (files, missing) in cases {
            let hub = FakeHub(["\(repo)@\(sha)": files])
            #expect(await makeModels(hub, directory: directory).checkRepo(repo) == .rejected(
                reason: .missingFiles, message: "\(repo) is missing \(missing), which MLX models need"
            ))
        }
    }

    @Test func `rejects a config.json too large to be real without reading it`() async {
        let files = mlxRepo().map { $0.path == "config.json" ? ($0.path, FakeFile(content: Data(count: 40_000_000))) : $0 }
        let hub = FakeHub(["\(repo)@\(sha)": files])
        #expect(await makeModels(hub, directory: directory).checkRepo(repo) == .rejected(
            reason: .missingFiles, message: "\(repo) has a config.json of 40 MB, too large to be a real one"
        ))
        #expect(hub.downloadedPaths.isEmpty)
    }

    @Test func `accepts a model only the vision registry knows as a vision model`() async throws {
        let config = #"{"model_type":"qwen3_vl","quantization":{"group_size":64,"bits":4},"vision_config":{}}"#
        let hub = FakeHub(["mlx-community/Qwen3-VL-8B-Instruct-4bit@\(sha)": mlxRepo(config: config)])
        let model = try compatible(await makeModels(hub, directory: directory).checkRepo("mlx-community/Qwen3-VL-8B-Instruct-4bit"))
        #expect(model.task == .vision && model.engine == .mlx)
        #expect(model.chatTemplateContext == nil)
    }
}
