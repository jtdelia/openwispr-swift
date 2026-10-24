import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import OpenWisprCore
import Tokenizers

/// A downloaded chat model in MLX format, run on the GPU. Loading reads the weights in a second or two;
/// the first generation also compiles Metal shaders for a few seconds, so `load` generates one token to
/// get that out of the way.
actor MLXChatEngine: ChatEngine {
    /// Models advertise up to 262K tokens, but the KV cache for that wouldn't fit in memory and the
    /// prompt would take many minutes to read. 32K covers a long meeting's transcript.
    private static let maxContextTokens = 32_768
    /// Freed GPU buffers MLX may keep for reuse between requests.
    private static let cacheLimitBytes = 512 * 1024 * 1024

    private let model: DownloadedModel
    private let contextSize: Int
    private var container: ModelContainer?
    private var loading: Task<ModelContainer, any Error>?
    private var warmedUp = false

    init(model: DownloadedModel) {
        self.model = model
        contextSize = (try? Self.contextSize(of: model)) ?? Self.maxContextTokens
    }

    /// The model's own limit from its `config.json`, capped to `maxContextTokens`.
    static func contextSize(of model: DownloadedModel) throws -> Int {
        struct Config: Decodable {
            struct Text: Decodable { let maxPositionEmbeddings: Int? }
            let maxPositionEmbeddings: Int?
            let textConfig: Text?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? Data(contentsOf: model.folder.appending(path: "config.json")),
              let config = try? decoder.decode(Config.self, from: data)
        else { throw ModelError.unavailable("\(model.name) has no readable config.json. Download it again in Settings → Models") }
        let limit = config.maxPositionEmbeddings ?? config.textConfig?.maxPositionEmbeddings ?? maxContextTokens
        return min(limit, maxContextTokens)
    }

    func load() async throws {
        let container = try await loadContainer()
        if warmedUp { return }
        let input = try await prepare([.user("Hi")], container: container)
        _ = try await generate(input, maxTokens: 1, container: container)
        warmedUp = true
    }

    func complete(_ messages: [ChatMessage], maxTokens wanted: Int) async throws -> String {
        let container = try await loadContainer()
        let input = try await prepare(messages, container: container)
        let maxTokens = try answerBudget(used: input.text.tokens.size, contextSize: contextSize, wanted: wanted, modelName: model.name)
        let (text, stopReason) = try await generate(input, maxTokens: maxTokens, container: container)
        warmedUp = true
        if stopReason == .length {
            throw ModelError.contextExceeded("The answer didn't fit in \(maxTokens) tokens")
        }
        return text
    }

    func unload() async {
        loading?.cancel()
        loading = nil
        container = nil
        warmedUp = false
        Memory.clearCache()
    }

    private func prepare(_ messages: [ChatMessage], container: ModelContainer) async throws -> sending LMInput {
        try await Self.prepare(messages, model: model, container: container)
    }

    /// Outside the actor, so the input is built in its own region and can be sent to the container.
    private nonisolated static func prepare(_ messages: [ChatMessage], model: DownloadedModel, container: ModelContainer) async throws -> sending LMInput {
        let chat = messages.map { Chat.Message(role: $0.role == .system ? .system : .user, content: $0.content) }
        do {
            return try await container.prepare(input: UserInput(chat: chat, additionalContext: model.entry.chatTemplateContext))
        } catch {
            throw ModelError.modelFailed("\(model.name) couldn't read the request: \(error.localizedDescription)")
        }
    }

    /// Greedy, like Apple's chat model, so Cleanup gives the same answer every time.
    private func generate(_ input: consuming sending LMInput, maxTokens: Int, container: ModelContainer) async throws -> (String, GenerateStopReason?) {
        let stream: AsyncStream<Generation>
        do {
            stream = try await container.generate(input: input, parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0))
        } catch {
            throw ModelError.modelFailed("\(model.name) couldn't answer: \(error.localizedDescription)")
        }
        var text = ""
        var stopReason: GenerateStopReason?
        for await generation in stream {
            switch generation {
            case let .chunk(chunk): text += chunk
            case let .info(info): stopReason = info.stopReason
            case .toolCall, .rejectedToolCall: break
            }
        }
        return (text, stopReason)
    }

    private func loadContainer() async throws -> ModelContainer {
        if let container { return container }
        if let loading { return try await loading.value }
        let task = Task { [model] in try await Self.createContainer(model) }
        loading = task
        defer { loading = nil }
        let container = try await task.value
        self.container = container
        return container
    }

    private static func createContainer(_ model: DownloadedModel) async throws -> ModelContainer {
        Memory.cacheLimit = cacheLimitBytes
        do {
            // The LLM factory, not `loadModelContainer`, which would load multimodal models' vision weights too.
            return try await LLMModelFactory.shared.loadContainer(from: model.folder, using: #huggingFaceTokenizerLoader())
        } catch let ModelFactoryError.unsupportedModelType(type) {
            throw ModelError.unavailable("\(model.name) is a \(type) model, which OpenWispr can't run")
        } catch {
            throw ModelError.modelFailed("\(model.name) couldn't be loaded: \(error.localizedDescription)")
        }
    }
}
