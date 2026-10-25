import Foundation
import MLX
import MLXNN
import OpenWisprCore
import Tokenizers

/// A downloaded Whisper checkpoint in Transformers format, like `openai/whisper-small.en`, run on the GPU
/// with MLX in float16. Loading reads the weights in a second or two, with nothing to compile. Decoding is
/// greedy with Whisper's timestamp rules, one 30 s window at a time, each conditioned on the text before it.
actor MLXWhisperEngine: SpeechToTextEngine {
    /// Half of Whisper's 448-token context, as OpenAI's decoder uses for the prompt and for each window.
    private static let maxPromptTokens = 223
    private static let maxSampledTokens = 224
    /// OpenAI's thresholds: a window is skipped as silence only when the model also wasn't confident.
    private static let noSpeechThreshold: Float = 0.6
    private static let lowLogProbability: Float = -1
    private static let cacheLimitBytes = 256 * 1024 * 1024

    private let model: DownloadedModel
    nonisolated let languages: [String]?
    private var loaded: LoadedWhisper?
    private var loading: Task<Void, any Error>?

    init(model: DownloadedModel) {
        self.model = model
        languages = model.entry.languageCodes
    }

    func load(language: String) async throws {
        _ = try languageToken(language, vocabulary: try vocabulary())
        try await loadModel()
    }

    func transcribe(_ samples: [Float], language: String, prompt: String) async throws -> [EngineTranscription.Segment] {
        let vocabulary = try vocabulary()
        let token = try languageToken(language, vocabulary: vocabulary)
        try await loadModel()
        guard let loaded else { throw ModelError.modelFailed("\(model.name) was unloaded while transcribing") }
        guard !samples.isEmpty else { return [] }
        let hint = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptTokens = hint.isEmpty ? [] : loaded.tokenizer.encode(text: " " + hint, addSpecialTokens: false).filter { $0 < vocabulary.endOfText }
        return try loaded.transcribe(samples, language: token, prompt: promptTokens)
    }

    func unload() async {
        loading?.cancel()
        loading = nil
        loaded = nil
        Memory.clearCache()
    }

    private func vocabulary() throws -> WhisperVocabulary {
        if let loaded { return loaded.vocabulary }
        guard let data = try? Data(contentsOf: model.folder.appending(path: "generation_config.json")),
              let vocabulary = try? WhisperVocabulary(generationConfig: data)
        else { throw ModelError.unavailable("\(model.name) has no readable generation_config.json. Download it again in Settings → Models") }
        return vocabulary
    }

    /// The language's token, or nil to detect it. Whisper silently returns nothing for a language it
    /// doesn't know, so those are rejected here.
    private func languageToken(_ language: String, vocabulary: WhisperVocabulary) throws -> Int? {
        guard let code = languageCode(language) else { return nil }
        if !vocabulary.isMultilingual {
            if code == "en" { return nil }
            throw ModelError.unsupportedLanguage("\(model.name) only transcribes English, not \(languageName(code))")
        }
        guard let token = vocabulary.languages[code] else {
            throw ModelError.unsupportedLanguage("\(model.name) doesn't support \(languageName(code))")
        }
        return token
    }

    private func loadModel() async throws {
        if loaded != nil { return }
        if let loading { return try await loading.value }
        let task = Task { try await self.createModel() }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func createModel() async throws {
        Memory.cacheLimit = Self.cacheLimitBytes
        do {
            let tokenizer = try await AutoTokenizer.from(modelFolder: model.folder)
            loaded = try LoadedWhisper(folder: model.folder, vocabulary: try vocabulary(), tokenizer: tokenizer)
        } catch let error as ModelError {
            throw error
        } catch {
            throw ModelError.modelFailed("\(model.name) couldn't be loaded: \(error.localizedDescription)")
        }
    }

    /// The model, its tokenizer and its mel filterbank. Not Sendable, so it never leaves the actor.
    private final class LoadedWhisper {
        let vocabulary: WhisperVocabulary
        let tokenizer: any Tokenizer
        private let config: WhisperModelConfig
        private let whisper: WhisperModel
        private let melFilters: MLXArray
        private let hannWindow: MLXArray

        init(folder: URL, vocabulary: WhisperVocabulary, tokenizer: any Tokenizer) throws {
            self.vocabulary = vocabulary
            self.tokenizer = tokenizer
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            config = try decoder.decode(WhisperModelConfig.self, from: Data(contentsOf: folder.appending(path: "config.json")))
            whisper = WhisperModel(config)
            try whisper.update(parameters: ModuleParameters.unflattened(try Self.weights(in: folder)), verify: [.all])
            eval(whisper)
            let bins = WhisperAudio.fftSize / 2 + 1
            melFilters = MLXArray(whisperMelFilters(melCount: config.numMelBins), [config.numMelBins, bins]).transposed()
            let size = Float(WhisperAudio.fftSize)
            hannWindow = MLXArray((0..<WhisperAudio.fftSize).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / size) })
        }

        /// Transformers names everything under `model.`, stores Conv1d kernels as (out, in, width) where MLX
        /// wants (out, width, in), and ties the output projection to the token embedding.
        private static func weights(in folder: URL) throws -> [String: MLXArray] {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "safetensors" }
            var weights: [String: MLXArray] = [:]
            for file in files {
                for (key, value) in try loadArrays(url: file) where key.hasPrefix("model.") {
                    let name = String(key.dropFirst("model.".count))
                    let weight = name.hasSuffix("conv1.weight") || name.hasSuffix("conv2.weight") ? value.transposed(0, 2, 1) : value
                    weights[name] = weight.asType(.float16)
                }
            }
            return weights
        }

        func transcribe(_ samples: [Float], language: Int?, prompt: [Int]) throws -> [EngineTranscription.Segment] {
            let contentFrames = samples.count / WhisperAudio.hopLength
            var language = language
            var context = prompt
            var segments: [EngineTranscription.Segment] = []
            var seek = 0
            while seek < contentFrames {
                try Task.checkCancellation()
                let frames = min(WhisperAudio.windowFrames, contentFrames - seek)
                let start = seek * WhisperAudio.hopLength
                let audio = whisper.encoder(logMel(samples[start..<min(samples.count, start + WhisperAudio.windowSamples)])[.newAxis])
                let crossKeysValues = whisper.decoder.crossKeysValues(audio)
                if vocabulary.isMultilingual && language == nil { language = detectLanguage(crossKeysValues) }
                let previous = context.isEmpty ? [] : [vocabulary.startOfPrevious] + context.suffix(MLXWhisperEngine.maxPromptTokens)
                let window = decode(crossKeysValues, prefix: previous + vocabulary.startSequence(language: language), startIndex: previous.count)
                let silent = window.noSpeechProbability > MLXWhisperEngine.noSpeechThreshold
                    && window.averageLogProbability < MLXWhisperEngine.lowLogProbability
                if silent {
                    seek += frames
                    continue
                }
                let (parts, consumed) = splitWhisperWindow(window.tokens, vocabulary: vocabulary, frames: frames)
                let offset = Double(start) / Double(speechSampleRate)
                segments += parts.map {
                    EngineTranscription.Segment(start: offset + $0.start, end: offset + $0.end, text: tokenizer.decode(tokens: $0.tokens, skipSpecialTokens: true))
                }
                context += window.tokens
                seek += consumed > 0 ? consumed : frames
            }
            return segments
        }

        /// The likeliest language token after the start token alone.
        private func detectLanguage(_ crossKeysValues: [(MLXArray, MLXArray)]) -> Int? {
            var cache = DecoderCache(crossKeysValues: crossKeysValues)
            let logits = whisper.decoder(MLXArray([Int32(vocabulary.startOfTranscript)])[.newAxis], cache: &cache)[0, -1]
            let candidates = vocabulary.languages.values.sorted()
            let scores = logits[MLXArray(candidates.map(Int32.init))].asType(.float32).asArray(Float.self)
            return scores.indices.max { scores[$0] < scores[$1] }.map { candidates[$0] }
        }

        private func decode(_ crossKeysValues: [(MLXArray, MLXArray)], prefix: [Int], startIndex: Int) -> DecodedWindow {
            var cache = DecoderCache(crossKeysValues: crossKeysValues)
            let first = whisper.decoder(MLXArray(prefix.map(Int32.init))[.newAxis], cache: &cache)
            let noSpeech = softmax(first[0, startIndex].asType(.float32))[vocabulary.noSpeech].item(Float.self)
            var logits = first[0, -1].asType(.float32).asArray(Float.self)
            var sampled: [Int] = []
            var logProbabilities: Float = 0
            while sampled.count < MLXWhisperEngine.maxSampledTokens && cache.offset < config.maxTargetPositions {
                let (token, logProbability) = nextWhisperToken(logits, sampled: sampled, vocabulary: vocabulary)
                if token == vocabulary.endOfText { break }
                sampled.append(token)
                logProbabilities += logProbability
                logits = whisper.decoder(MLXArray([Int32(token)])[.newAxis], cache: &cache)[0, -1].asType(.float32).asArray(Float.self)
            }
            return DecodedWindow(
                tokens: sampled, noSpeechProbability: noSpeech, averageLogProbability: logProbabilities / Float(max(1, sampled.count))
            )
        }

        /// Whisper's log-mel spectrogram of up to 30 s, zero-padded to 30 s as Transformers' feature
        /// extractor does: reflect-padded STFT, power spectrum, mel filterbank, then log10 clamped to 8
        /// below its peak and scaled to about -1...1.
        private func logMel(_ samples: ArraySlice<Float>) -> MLXArray {
            let half = WhisperAudio.fftSize / 2
            var audio = Array(samples)
            audio += [Float](repeating: 0, count: WhisperAudio.windowSamples - audio.count)
            let padded = (1...half).reversed().map { audio[$0] } + audio + (1...half).map { audio[audio.count - 1 - $0] }
            let starts = MLXArray(0..<WhisperAudio.windowFrames).asType(.int32) * Int32(WhisperAudio.hopLength)
            let indices = starts.expandedDimensions(axis: 1) + MLXArray(0..<WhisperAudio.fftSize).asType(.int32).expandedDimensions(axis: 0)
            let frames = take(MLXArray(padded), indices) * hannWindow
            let power = square(abs(rfft(frames, axis: -1)))
            let mel = log10(maximum(matmul(power, melFilters), 1e-10))
            let clamped = maximum(mel, mel.max() - 8)
            return ((clamped + 4) / 4).asType(.float16)
        }
    }
}

private struct DecodedWindow {
    var tokens: [Int]
    var noSpeechProbability: Float
    var averageLogProbability: Float
}

private struct WhisperModelConfig: Decodable {
    var dModel: Int
    var numMelBins: Int
    var vocabSize: Int
    var encoderLayers: Int
    var encoderAttentionHeads: Int
    var encoderFfnDim: Int
    var decoderLayers: Int
    var decoderAttentionHeads: Int
    var decoderFfnDim: Int
    var maxSourcePositions: Int
    var maxTargetPositions: Int
}

/// Each decoder layer's keys and values so far, and the encoder's, computed once per window.
private struct DecoderCache {
    var crossKeysValues: [(MLXArray, MLXArray)]
    var selfKeysValues: [(MLXArray, MLXArray)?] = []
    var offset = 0
}

private final class WhisperAttention: Module {
    @ModuleInfo(key: "q_proj") var queryProjection: Linear
    @ModuleInfo(key: "k_proj") var keyProjection: Linear
    @ModuleInfo(key: "v_proj") var valueProjection: Linear
    @ModuleInfo(key: "out_proj") var outProjection: Linear
    let heads: Int
    let scale: Float

    init(dimensions: Int, heads: Int) {
        self.heads = heads
        scale = 1 / Float(dimensions / heads).squareRoot()
        _queryProjection.wrappedValue = Linear(dimensions, dimensions)
        _keyProjection.wrappedValue = Linear(dimensions, dimensions, bias: false)
        _valueProjection.wrappedValue = Linear(dimensions, dimensions)
        _outProjection.wrappedValue = Linear(dimensions, dimensions)
    }

    func keysValues(_ x: MLXArray) -> (MLXArray, MLXArray) {
        (splitHeads(keyProjection(x)), splitHeads(valueProjection(x)))
    }

    func callAsFunction(_ x: MLXArray, keysValues: (MLXArray, MLXArray), mask: MLXArray? = nil) -> MLXArray {
        let output = scaledDotProductAttention(
            queries: splitHeads(queryProjection(x)), keys: keysValues.0, values: keysValues.1, scale: scale, mask: mask
        )
        return outProjection(output.transposed(0, 2, 1, 3).reshaped(x.dim(0), x.dim(1), -1))
    }

    private func splitHeads(_ x: MLXArray) -> MLXArray {
        x.reshaped(x.dim(0), x.dim(1), heads, -1).transposed(0, 2, 1, 3)
    }
}

private final class WhisperEncoderLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: WhisperAttention
    @ModuleInfo(key: "self_attn_layer_norm") var attentionNorm: LayerNorm
    @ModuleInfo var fc1: Linear
    @ModuleInfo var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalNorm: LayerNorm

    init(dimensions: Int, heads: Int, ffnDimensions: Int) {
        _attention.wrappedValue = WhisperAttention(dimensions: dimensions, heads: heads)
        _attentionNorm.wrappedValue = LayerNorm(dimensions: dimensions)
        fc1 = Linear(dimensions, ffnDimensions)
        fc2 = Linear(ffnDimensions, dimensions)
        _finalNorm.wrappedValue = LayerNorm(dimensions: dimensions)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let normed = attentionNorm(x)
        let x = x + attention(normed, keysValues: attention.keysValues(normed))
        return x + fc2(gelu(fc1(finalNorm(x))))
    }
}

private final class WhisperEncoder: Module {
    @ModuleInfo var conv1: Conv1d
    @ModuleInfo var conv2: Conv1d
    @ModuleInfo(key: "embed_positions") var positions: Embedding
    @ModuleInfo var layers: [WhisperEncoderLayer]
    @ModuleInfo(key: "layer_norm") var norm: LayerNorm

    init(_ config: WhisperModelConfig) {
        conv1 = Conv1d(inputChannels: config.numMelBins, outputChannels: config.dModel, kernelSize: 3, padding: 1)
        conv2 = Conv1d(inputChannels: config.dModel, outputChannels: config.dModel, kernelSize: 3, stride: 2, padding: 1)
        _positions.wrappedValue = Embedding(embeddingCount: config.maxSourcePositions, dimensions: config.dModel)
        layers = (0..<config.encoderLayers).map { _ in
            WhisperEncoderLayer(dimensions: config.dModel, heads: config.encoderAttentionHeads, ffnDimensions: config.encoderFfnDim)
        }
        _norm.wrappedValue = LayerNorm(dimensions: config.dModel)
    }

    /// `mel` is (1, frames, mels).
    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        var x = gelu(conv2(gelu(conv1(mel))))
        x += positions.weight[0..<x.dim(1)]
        for layer in layers { x = layer(x) }
        return norm(x)
    }
}

private final class WhisperDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: WhisperAttention
    @ModuleInfo(key: "self_attn_layer_norm") var attentionNorm: LayerNorm
    @ModuleInfo(key: "encoder_attn") var crossAttention: WhisperAttention
    @ModuleInfo(key: "encoder_attn_layer_norm") var crossAttentionNorm: LayerNorm
    @ModuleInfo var fc1: Linear
    @ModuleInfo var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalNorm: LayerNorm

    init(dimensions: Int, heads: Int, ffnDimensions: Int) {
        _attention.wrappedValue = WhisperAttention(dimensions: dimensions, heads: heads)
        _attentionNorm.wrappedValue = LayerNorm(dimensions: dimensions)
        _crossAttention.wrappedValue = WhisperAttention(dimensions: dimensions, heads: heads)
        _crossAttentionNorm.wrappedValue = LayerNorm(dimensions: dimensions)
        fc1 = Linear(dimensions, ffnDimensions)
        fc2 = Linear(ffnDimensions, dimensions)
        _finalNorm.wrappedValue = LayerNorm(dimensions: dimensions)
    }

    func callAsFunction(_ x: MLXArray, previous: (MLXArray, MLXArray)?, cross: (MLXArray, MLXArray), mask: MLXArray?) -> (MLXArray, (MLXArray, MLXArray)) {
        let normed = attentionNorm(x)
        var (keys, values) = attention.keysValues(normed)
        if let previous {
            keys = concatenated([previous.0, keys], axis: 2)
            values = concatenated([previous.1, values], axis: 2)
        }
        var x = x + attention(normed, keysValues: (keys, values), mask: mask)
        x += crossAttention(crossAttentionNorm(x), keysValues: cross)
        return (x + fc2(gelu(fc1(finalNorm(x)))), (keys, values))
    }
}

private final class WhisperDecoder: Module {
    @ModuleInfo(key: "embed_tokens") var tokens: Embedding
    @ModuleInfo(key: "embed_positions") var positions: Embedding
    @ModuleInfo var layers: [WhisperDecoderLayer]
    @ModuleInfo(key: "layer_norm") var norm: LayerNorm

    init(_ config: WhisperModelConfig) {
        _tokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.dModel)
        _positions.wrappedValue = Embedding(embeddingCount: config.maxTargetPositions, dimensions: config.dModel)
        layers = (0..<config.decoderLayers).map { _ in
            WhisperDecoderLayer(dimensions: config.dModel, heads: config.decoderAttentionHeads, ffnDimensions: config.decoderFfnDim)
        }
        _norm.wrappedValue = LayerNorm(dimensions: config.dModel)
    }

    func crossKeysValues(_ audio: MLXArray) -> [(MLXArray, MLXArray)] {
        layers.map { $0.crossAttention.keysValues(audio) }
    }

    /// Logits for each of `ids` (1, count), continuing from `cache`.
    func callAsFunction(_ ids: MLXArray, cache: inout DecoderCache) -> MLXArray {
        let count = ids.dim(1)
        var x = tokens(ids) + positions.weight[cache.offset..<(cache.offset + count)]
        let mask: MLXArray? = count > 1 ? causalMask(count, offset: cache.offset).asType(x.dtype) : nil
        if cache.selfKeysValues.isEmpty { cache.selfKeysValues = Array(repeating: nil, count: layers.count) }
        for (index, layer) in layers.enumerated() {
            let (output, keysValues) = layer(x, previous: cache.selfKeysValues[index], cross: cache.crossKeysValues[index], mask: mask)
            x = output
            cache.selfKeysValues[index] = keysValues
        }
        cache.offset += count
        return tokens.asLinear(norm(x))
    }

    private func causalMask(_ count: Int, offset: Int) -> MLXArray {
        let rows = MLXArray(0..<count).expandedDimensions(axis: 1) + offset
        let columns = MLXArray(0..<(offset + count)).expandedDimensions(axis: 0)
        return MLX.where(columns .> rows, MLXArray(-Float.infinity), MLXArray(Float(0)))
    }
}

private final class WhisperModel: Module {
    @ModuleInfo var encoder: WhisperEncoder
    @ModuleInfo var decoder: WhisperDecoder

    init(_ config: WhisperModelConfig) {
        encoder = WhisperEncoder(config)
        decoder = WhisperDecoder(config)
    }
}
