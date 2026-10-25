import Foundation

/// `model_type`s that mlx-swift-lm 3.32.3 registers; keep in step with the version in `Packages/OpenWisprEngines`.
private let mlxLlmTypes = Set((
    "mistral mixtral llama phi phi3 phimoe gemma gemma2 gemma3 gemma3_text gemma3n gemma4 gemma4_unified gemma4_text "
        + "qwen2 qwen3 qwen3_moe qwen3_next qwen3_5 qwen3_5_moe qwen3_5_text nanbeige minicpm starcoder2 cohere openelm "
        + "internlm2 deepseek_v2 deepseek_v3 granite helium granitemoehybrid mimo mimo_v2_flash minimax glm4 glm4_moe "
        + "glm4_moe_lite acereason falcon_h1 bitnet smollm3 ernie4_5 lfm2 baichuan_m1 exaone4 gpt_oss lille-130m olmoe "
        + "olmo2 olmo3 bailing_moe lfm2_moe nanochat nemotron_h afmoe jamba mamba2 mistral3 apertus hunyuan_v1_dense "
        + "nemotron_labs_diffusion"
).split(separator: " ").map(String.init))

private let mlxVlmTypes = Set((
    "paligemma qwen2_vl qwen2_5_vl qwen3_vl qwen3_vl_moe qwen3_5 qwen3_5_moe idefics3 gemma3 gemma4 gemma4_unified "
        + "smolvlm fastvlm llava_qwen2 pixtral mistral3 lfm2_vl lfm2-vl glm_ocr muse_glimmer"
).split(separator: " ").map(String.init))

/// Top-level files an MLX model folder may need: configs, weights, tokenizer and chat template.
private let mlxFile = #"\.(json|safetensors|jinja|txt|model|tiktoken)$"#
/// Measured: MLX 4-bit models peak at about 1.3× their weights for short prompts.
private let mlxMemoryFactor = 1.3
private let whisperKitModels = ["AudioEncoder", "MelSpectrogram", "TextDecoder"]
/// FluidAudio's `loadLocal(version: .v3)` reads exactly these.
private let parakeetModels = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
private let parakeetVocab = "parakeet_vocab.json"
private let whisperSizes = [384: "tiny", 512: "base", 768: "small", 1024: "medium", 1280: "large"]
private let whisperEnglishVocab = 51864
private let whisperMultilingualVocab = 51865
private let whisperV3Vocab = 51866
/// Measured on the Recommended Core ML models: about 1.7× their download while loaded.
private let coreMlMemoryFactor = 1.7
/// What the MLX Whisper engine reads besides the weights.
private let whisperTransformersFiles = ["config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json"]
/// Measured: openai/whisper-medium.en peaks at about 1.7× its float16 weights while loading and transcribing.
private let mlxWhisperMemoryFactor = 1.7
/// swift-transformers loads a tokenizer from these two files only.
private let mlxTokenizer = ["tokenizer.json", "tokenizer_config.json"]
/// Far above real configs and chat templates (a tokenizer_config.json is at most a few MB).
private let maxTextFileBytes: Int64 = 32_000_000
private let findMlx = "Look for an MLX version, often from mlx-community"

/// Where a repo check reads a repo: Hugging Face itself, or the local Hugging Face cache.
public protocol HubRepoSource: Sendable {
    /// `revision` is a branch, tag or sha; without it, the head of the default branch.
    func repoInfo(_ repo: String, revision: String?) async throws -> RepoInfo
    /// Every file in `repo` at `revision`, or only those under `folder`.
    func listRepoFiles(repo: String, revision: String, folder: String?) async throws -> [HubFile]
    /// A small file's text, like `config.json`.
    func readRepoFile(repo: String, revision: String, path: String) async throws -> String
}

extension HuggingFace: HubRepoSource {}

/// A `RepoCheck` before `Models` weighs a compatible model against this Mac's memory.
public enum HubRepoCheck: Sendable, Equatable {
    case compatible(model: ModelEntry, summary: String)
    case severalModels(repo: String, revision: String, folders: [String], message: String)
    case rejected(reason: RepoRejection, message: String)
}

public struct RepoReference: Sendable, Equatable {
    public var repo: String
    public var revision: String?
    public var folder: String?

    public init(repo: String, revision: String? = nil, folder: String? = nil) {
        self.repo = repo
        self.revision = revision
        self.folder = folder
    }
}

private struct Rejected: Error {
    let reason: RepoRejection
    let message: String
}

/// Accepts `org/name` or a huggingface.co URL, including `/tree/<rev>/<folder>` and `/blob/<rev>/<file>` links.
public func parseRepoReference(_ input: String) -> RepoReference? {
    let trimmed = input.trimmed.replacing(pattern: "[?#].*$", with: "").replacing(pattern: "/+$", with: "")
    let path = trimmed.replacing(pattern: #"^(https?://)?(www\.)?(huggingface\.co|hf\.co)/"#, with: "", caseInsensitive: true)
    guard let match = path.firstMatch(#"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:/(tree|blob|resolve)/([^/]+)(?:/(.+))?)?$"#),
          let repo = match[1], !repo.matches("^(datasets|spaces)/")
    else { return nil }
    let kind = match[2]
    let rest = match[4]
    let folder: String? = if kind == "tree" {
        rest
    } else if let rest, let slash = rest.lastIndex(of: "/") {
        String(rest[..<slash])
    } else {
        nil
    }
    return RepoReference(repo: repo, revision: match[3], folder: folder.map { $0.removingPercentEncoding ?? $0 })
}

private struct Pinned {
    var repo: String
    var revision: String
    var folder: String?

    var label: String { folder.map { "\(repo)/\($0)" } ?? repo }

    func path(_ rel: String) -> String { folder.map { "\($0)/\(rel)" } ?? rel }
}

/// A listed file with its path relative to the model's folder.
private struct Listed {
    var file: HubFile
    var rel: String
    var path: String { file.path }
    var size: Int64 { file.size }
}

private func label(_ repo: String, _ folder: String?) -> String { folder.map { "\(repo)/\($0)" } ?? repo }

private func sum(_ files: [Listed]) -> Int64 { files.reduce(0) { $0 + $1.size } }

/// Whether OpenWispr can run the model in a pasted repo, and the entry to download it with if so.
public func checkHubRepo(_ hub: any HubRepoSource, _ input: String) async -> HubRepoCheck {
    guard let ref = parseRepoReference(input) else {
        return .rejected(reason: .invalidReference, message: "Paste a Hugging Face model id like mlx-community/Qwen3-4B-Instruct-2507-4bit, or its URL")
    }
    do {
        let info = try await hub.repoInfo(ref.repo, revision: ref.revision)
        if info.gated {
            throw Rejected(
                reason: .gated,
                message: "\(ref.repo) is gated: its owner approves each download, and OpenWispr downloads without a Hugging Face account"
            )
        }
        let listed = try await hub.listRepoFiles(repo: ref.repo, revision: info.sha, folder: ref.folder)
        let check = try await classify(hub, Pinned(repo: ref.repo, revision: info.sha, folder: ref.folder), info, listed)
        if case let .compatible(model, _) = check, let first = model.sources.first,
           let listedAs = recommendedModels.first(where: { $0.sources[0].repo == first.repo && $0.sources[0].folder == first.folder }) {
            throw Rejected(reason: .alreadyListed, message: "\(label(first.repo, first.folder)) is already in Recommended models as \(listedAs.name)")
        }
        return check
    } catch {
        let rejected = asRejection(error)
        return .rejected(reason: rejected.reason, message: rejected.message)
    }
}

private func asRejection(_ error: any Error) -> Rejected {
    if let rejected = error as? Rejected { return rejected }
    if let error = error as? HubError {
        switch error.code {
        case "GatedRepo": return Rejected(reason: .gated, message: error.message)
        case "RevisionNotFound": return Rejected(reason: .notFoundOrPrivate, message: error.message)
        case "EntryNotFound": return Rejected(reason: .missingFiles, message: error.message)
        default: break
        }
        if error.status == 401 {
            return Rejected(reason: .notFoundOrPrivate, message: "\(error.message). Check the spelling; private repos can't be downloaded")
        }
        return Rejected(reason: .hubFailed, message: error.message)
    }
    return Rejected(reason: .hubFailed, message: "Couldn't check the repo on Hugging Face: \(errorMessage(error))")
}

private func classify(_ hub: any HubRepoSource, _ ref: Pinned, _ info: RepoInfo, _ listed: [HubFile]) async throws -> HubRepoCheck {
    let prefix = ref.folder.map { "\($0)/" } ?? ""
    let files = listed.filter { $0.path.hasPrefix(prefix) }.map { Listed(file: $0, rel: String($0.path.dropFirst(prefix.count))) }
    let dirs = Set(files.filter { $0.rel.contains("/") }.map { String($0.rel.split(separator: "/")[0]) })
    if whisperKitModels.contains(where: { dirs.contains("\($0).mlmodelc") }) { return try await whisperKit(hub, ref, files) }
    if parakeetModels.contains(where: { dirs.contains("\($0).mlmodelc") }) || files.contains(where: { $0.rel == parakeetVocab }) {
        return try fluidAudio(ref, files)
    }
    if files.contains(where: { !$0.rel.contains("/") && $0.rel.hasSuffix(".safetensors") }) { return try await mlx(hub, ref, info, files) }
    if ref.folder == nil {
        let folders = speechFolders(files)
        if folders.count == 1 {
            var nested = ref
            nested.folder = folders[0]
            return try await classify(hub, nested, info, listed)
        }
        if folders.count > 1 {
            return .severalModels(
                repo: ref.repo, revision: ref.revision, folders: folders, message: "\(ref.repo) holds \(folders.count) speech-to-text models. Choose one"
            )
        }
    }
    if files.contains(where: { $0.rel.hasSuffix(".gguf") }) {
        throw Rejected(
            reason: .ggufOnly,
            message: "\(ref.label) only has GGUF weights, which are for llama.cpp. OpenWispr runs chat models with MLX: look for an MLX version, often from mlx-community"
        )
    }
    throw Rejected(reason: .missingFiles, message: "\(ref.label) has no MLX weights (.safetensors)")
}

/// Folders below the repo root that hold a WhisperKit or FluidAudio model.
private func speechFolders(_ files: [Listed]) -> [String] {
    let marker = "^(.+)/(\((whisperKitModels + parakeetModels).joined(separator: "|")))\\.mlmodelc/"
    return Array(Set(files.compactMap { $0.rel.firstMatch(marker)?[1] ?? nil })).sorted()
}

private struct WhisperConfig: Decodable {
    var nameOrPath: String?
    var vocabSize: Int?
    var dModel: Int?
    var numMelBins: Int?
    var torchDtype: String?
    var quantization: MlxConfig.Quantization?
    var quantizationConfig: MlxConfig.Quantization?

    enum CodingKeys: String, CodingKey {
        case nameOrPath = "_name_or_path", vocabSize = "vocab_size", dModel = "d_model", numMelBins = "num_mel_bins"
        case torchDtype = "torch_dtype", quantization, quantizationConfig = "quantization_config"
    }
}

private func whisperKit(_ hub: any HubRepoSource, _ ref: Pinned, _ files: [Listed]) async throws -> HubRepoCheck {
    let has = { (rel: String) in files.contains { $0.rel == rel } }
    let missing = whisperKitModels.map { "\($0).mlmodelc" }.filter { !has("\($0)/coremldata.bin") } + ["config.json"].filter { !has($0) }
    if !missing.isEmpty { throw missingFiles(ref.label, missing, needs: "WhisperKit needs") }
    let config = try JSONDecoder().decode(WhisperConfig.self, from: Data(try await readSmallFile(hub, ref, files, "config.json").utf8))
    guard let tokenizerRepo = whisperTokenizerRepo(config) else {
        throw Rejected(reason: .unsupportedArchitecture, message: "\(ref.label) has a config.json that isn't one of the Whisper models WhisperKit runs")
    }
    let picked = files.filter { $0.rel.matches(#"^[^/]+\.mlmodelc/"#) || $0.rel.matches(#"^[^/]+\.json$"#) }
    let pickedPaths = Set(picked.map { $0.rel.contains("/") ? ref.path("\($0.rel.split(separator: "/")[0])/") : $0.path }).sorted()
    var sources = [source(ref, pickedPaths)]
    var sizeBytes = sum(picked)
    if !whisperTokenizer.allSatisfy(has) {
        let tokenizer = try await hub.repoInfo(tokenizerRepo, revision: nil)
        let listed = try await hub.listRepoFiles(repo: tokenizerRepo, revision: tokenizer.sha, folder: nil)
        let tokenizerFiles = listed.filter { whisperTokenizer.contains($0.path) }
        let absent = whisperTokenizer.filter { rel in !tokenizerFiles.contains { $0.path == rel } }
        if !absent.isEmpty { throw missingFiles(tokenizerRepo, absent, needs: "WhisperKit needs") }
        sources.append(ModelSource(repo: tokenizerRepo, revision: tokenizer.sha, files: whisperTokenizer))
        sizeBytes += tokenizerFiles.reduce(0) { $0 + $1.size }
    }
    let english = config.vocabSize == whisperEnglishVocab
    let (id, name) = identity(ref)
    return .compatible(
        model: ModelEntry(
            id: id, name: name, task: .speechToText, engine: .whisperKit, sources: sources, sizeBytes: sizeBytes,
            memoryBytes: Int64((Double(sizeBytes) * coreMlMemoryFactor).rounded()), speed: whisperSpeed(sizeBytes),
            languages: english ? "English" : "99 languages", languageCodes: english ? ["en"] : nil
        ),
        summary: "WhisperKit (Core ML), tokenizer from \(tokenizerRepo)"
    )
}

/// A Whisper checkpoint in Transformers format, like `openai/whisper-small.en` or distil-whisper's, which
/// the MLX Whisper engine runs from its safetensors. Repos often carry the same weights for PyTorch,
/// TensorFlow and Flax too, and some an fp32 copy in shards beside `model.safetensors`; only one set is fetched.
private func transformersWhisper(_ hub: any HubRepoSource, _ ref: Pinned, _ top: [Listed], _ configText: String) async throws -> HubRepoCheck {
    let config = try JSONDecoder().decode(WhisperConfig.self, from: Data(configText.utf8))
    // Conversions for mlx-audio or mlx-examples also say `whisper`, but name their weights differently and may be quantized.
    if config.dModel == nil || config.numMelBins == nil || config.quantization != nil || config.quantizationConfig != nil {
        throw Rejected(
            reason: .unsupportedArchitecture,
            message: "\(ref.label) is a Whisper converted for another runtime. OpenWispr runs OpenAI's own checkpoints, like openai/whisper-small.en"
        )
    }
    let has = { (rel: String) in top.contains { $0.rel == rel } }
    let weights = has("model.safetensors") ? ["model.safetensors"] : top.map(\.rel).filter { $0.matches(#"^model-\d+-of-\d+\.safetensors$"#) }
    let missing = (whisperTransformersFiles + (weights.isEmpty ? ["model.safetensors"] : missingShards(top.filter { weights.contains($0.rel) })))
        .filter { !has($0) }
    if !missing.isEmpty { throw missingFiles(ref.label, missing, needs: "Whisper on MLX needs") }
    let generation = try await readSmallFile(hub, ref, top, "generation_config.json")
    guard let vocabulary = try? WhisperVocabulary(generationConfig: Data(generation.utf8)) else {
        throw Rejected(reason: .missingFiles, message: "\(ref.label) has a generation_config.json without Whisper's special tokens")
    }
    let picked = top.filter { weights.contains($0.rel) || whisperTransformersFiles.contains($0.rel) }
    let weightBytes = sum(picked.filter { weights.contains($0.rel) })
    // The engine runs in float16, so fp32 weights take half their size once loaded.
    let loadedBytes = config.torchDtype == "float32" ? weightBytes / 2 : weightBytes
    let english = !vocabulary.isMultilingual
    let (id, name) = identity(ref)
    return .compatible(
        model: ModelEntry(
            id: id, name: name, task: .speechToText, engine: .mlxWhisper, sources: [source(ref, picked.map(\.path).sorted())],
            sizeBytes: sum(picked), memoryBytes: Int64((Double(loadedBytes) * mlxWhisperMemoryFactor).rounded()),
            speed: whisperSpeed(loadedBytes), languages: english ? "English" : "\(vocabulary.languages.count) languages",
            languageCodes: english ? ["en"] : nil
        ),
        summary: "Whisper on MLX, \(config.torchDtype ?? "float16") weights"
    )
}

/// WhisperKit folders ship without a tokenizer, so it comes from OpenAI's repo for the same model: the one
/// the config names, else the one its vocabulary (large-v3 added a token, English-only models lack one)
/// and width identify.
private func whisperTokenizerRepo(_ config: WhisperConfig) -> String? {
    if let named = config.nameOrPath?.firstMatch(#"^openai/whisper-[A-Za-z0-9_.-]+$"#)?[0] { return named }
    if config.vocabSize == whisperV3Vocab { return "openai/whisper-large-v3" }
    guard let size = whisperSizes[config.dModel ?? 0] else { return nil }
    if config.vocabSize == whisperMultilingualVocab { return "openai/whisper-\(size == "large" ? "large-v2" : size)" }
    if config.vocabSize == whisperEnglishVocab && size != "large" { return "openai/whisper-\(size).en" }
    return nil
}

private func whisperSpeed(_ sizeBytes: Int64) -> SpeedTier {
    if sizeBytes < 150_000_000 { return .fastest }
    if sizeBytes < 400_000_000 { return .fast }
    if sizeBytes < 1_200_000_000 { return .medium }
    return .slow
}

private func fluidAudio(_ ref: Pinned, _ files: [Listed]) throws -> HubRepoCheck {
    let dirs = parakeetModels.map { "\($0).mlmodelc" }
    let missing = dirs.filter { dir in !files.contains { $0.rel == "\(dir)/coremldata.bin" } }
        + [parakeetVocab].filter { rel in !files.contains { $0.rel == rel } }
    if !missing.isEmpty { throw missingFiles(ref.label, missing, needs: "Parakeet TDT v3 needs") }
    let picked = files.filter { file in file.rel == parakeetVocab || dirs.contains { file.rel.hasPrefix("\($0)/") } }
    let sizeBytes = sum(picked)
    let (id, name) = identity(ref)
    return .compatible(
        model: ModelEntry(
            id: id, name: name, task: .speechToText, engine: .fluidAudio,
            sources: [source(ref, (dirs.map { ref.path("\($0)/") } + [ref.path(parakeetVocab)]).sorted())],
            sizeBytes: sizeBytes, memoryBytes: Int64((Double(sizeBytes) * coreMlMemoryFactor).rounded()), speed: .fastest,
            languages: "25 European languages", languageCodes: parakeetLanguages
        ),
        summary: "Parakeet TDT v3 (FluidAudio, Core ML)"
    )
}

private struct MlxConfig: Decodable {
    struct Quantization: Decodable {
        var bits: Int?
        var groupSize: Int?
        var quantMethod: String?

        enum CodingKeys: String, CodingKey {
            case bits, groupSize = "group_size", quantMethod = "quant_method"
        }
    }

    var modelType: String?
    var quantization: Quantization?
    var quantizationConfig: Quantization?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type", quantization, quantizationConfig = "quantization_config"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try? container.decodeIfPresent(String.self, forKey: .modelType)
        quantization = try? container.decodeIfPresent(Quantization.self, forKey: .quantization)
        quantizationConfig = try? container.decodeIfPresent(Quantization.self, forKey: .quantizationConfig)
    }
}

private func mlx(_ hub: any HubRepoSource, _ ref: Pinned, _ info: RepoInfo, _ files: [Listed]) async throws -> HubRepoCheck {
    let top = files.filter { !$0.rel.contains("/") }
    let has = { (rel: String) in top.contains { $0.rel == rel } }
    if !has("config.json") { throw missingFiles(ref.label, ["config.json"], needs: "MLX models need") }
    let configText = try await readSmallFile(hub, ref, top, "config.json")
    let config = try JSONDecoder().decode(MlxConfig.self, from: Data(configText.utf8))
    if config.modelType == "whisper" { return try await transformersWhisper(hub, ref, top, configText) }
    let bits = try mlxBits(ref, config)
    let modelType = config.modelType ?? ""
    guard let task = mlxTask(modelType) else {
        throw Rejected(
            reason: .unsupportedArchitecture,
            message: "\(ref.label) uses the \(modelType.isEmpty ? "unnamed" : modelType) architecture, which OpenWispr's MLX engine doesn't support yet"
        )
    }
    let missing = (mlxTokenizer + missingShards(top)).filter { !has($0) }
    if !missing.isEmpty { throw missingFiles(ref.label, missing, needs: "MLX models need") }
    let picked = top.filter { $0.rel.matches(mlxFile) }
    let weightBytes = sum(picked.filter { $0.rel.hasSuffix(".safetensors") })
    let template = try await readSmallFile(
        hub, ref, top, picked.contains { $0.rel == "chat_template.jinja" } ? "chat_template.jinja" : "tokenizer_config.json"
    )
    let thinks = task == .chat && template.contains("enable_thinking")
    let (id, name) = identity(ref)
    let count = info.languages.count
    return .compatible(
        model: ModelEntry(
            id: id, name: name, task: task, engine: .mlx, sources: [source(ref, picked.map(\.path).sorted())], sizeBytes: sum(picked),
            memoryBytes: Int64((Double(weightBytes) * mlxMemoryFactor).rounded()), speed: mlxSpeed(weightBytes),
            languages: count == 0 ? "Languages not listed" : "\(count) language\(count == 1 ? "" : "s")", languageCodes: nil,
            chatTemplateContext: thinks ? ["enable_thinking": false] : nil
        ),
        summary: "MLX \(modelType), \(bits)-bit"
    )
}

/// mlx-lm writes `quantization` (newer versions also copy it to `quantization_config`); a
/// `quantization_config` with a `quant_method` is a Transformers format such as GPTQ or AWQ instead.
private func mlxBits(_ ref: Pinned, _ config: MlxConfig) throws -> Int {
    if let foreign = config.quantizationConfig?.quantMethod, config.quantization == nil {
        throw Rejected(reason: .notMlx, message: "\(ref.label) is quantized with \(foreign), which MLX can't load. \(findMlx)")
    }
    guard let quantization = config.quantization ?? config.quantizationConfig, let bits = quantization.bits, quantization.groupSize != nil else {
        throw Rejected(
            reason: .notMlx,
            message: "\(ref.label) has no MLX quantization config, so its weights aren't quantized for MLX. Look for a 4-bit MLX version, often from mlx-community"
        )
    }
    return bits
}

/// Sharded weights are named `model-0000i-of-0000n.safetensors`; every shard must be there.
private func missingShards(_ top: [Listed]) -> [String] {
    guard let shard = top.lazy.compactMap({ $0.rel.firstMatch(#"^(.*)-(\d+)-of-(\d+)\.safetensors$"#) }).first,
          let stem = shard[1], let index = shard[2], let countText = shard[3], let count = Int(countText)
    else { return [] }
    if count > top.count { return ["most of the \(countText) shards of \(stem).safetensors"] }
    return (0..<count).map { $0 + 1 }.map { i in
        let number = String(i)
        return "\(stem)-\(String(repeating: "0", count: max(0, index.count - number.count)))\(number)-of-\(countText).safetensors"
    }
}

/// Types in both registries, like `qwen3_5`, are chat models with a vision tower the chat engine skips.
private func mlxTask(_ modelType: String) -> ModelTask? {
    if mlxLlmTypes.contains(modelType) { return .chat }
    if mlxVlmTypes.contains(modelType) { return .vision }
    return nil
}

private func mlxSpeed(_ weightBytes: Int64) -> SpeedTier {
    if weightBytes < 1_000_000_000 { return .fastest }
    if weightBytes < 3_500_000_000 { return .fast }
    if weightBytes < 8_000_000_000 { return .medium }
    return .slow
}

/// Reads a config or template the listing shows as small, since a repo can publish any size.
private func readSmallFile(_ hub: any HubRepoSource, _ ref: Pinned, _ files: [Listed], _ rel: String) async throws -> String {
    let size = files.first { $0.rel == rel }?.size ?? 0
    if size > maxTextFileBytes {
        throw Rejected(reason: .missingFiles, message: "\(ref.label) has a \(rel) of \(Int((Double(size) / 1e6).rounded())) MB, too large to be a real one")
    }
    return try await hub.readRepoFile(repo: ref.repo, revision: ref.revision, path: ref.path(rel))
}

private func missingFiles(_ label: String, _ missing: [String], needs: String) -> Rejected {
    let list = missing.count == 1 ? missing[0] : "\(missing.dropLast().joined(separator: ", ")) and \(missing.last ?? "")"
    return Rejected(reason: .missingFiles, message: "\(label) is missing \(list), which \(needs)")
}

private func identity(_ ref: Pinned) -> (id: String, name: String) {
    let joined = ([ref.repo] + (ref.folder.map { [$0] } ?? [])).joined(separator: "/")
    let id = "hf-\(joined.replacingOccurrences(of: "/", with: "--").replacing(pattern: #"[^A-Za-z0-9_.-]"#, with: "-"))"
    let name = ref.folder?.split(separator: "/").last.map(String.init) ?? String(ref.repo.split(separator: "/")[1])
    return (id, name)
}

private func source(_ ref: Pinned, _ files: [String]) -> ModelSource {
    ModelSource(repo: ref.repo, revision: ref.revision, folder: ref.folder, files: files)
}
