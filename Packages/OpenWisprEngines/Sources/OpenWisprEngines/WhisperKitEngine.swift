import Foundation
import OpenWisprCore
import WhisperKit

/// A downloaded Whisper model in WhisperKit's Core ML format. The first load of a model compiles it for the
/// Neural Engine (half a minute to two minutes); macOS caches the result, so later loads take a second or two.
/// WhisperKit isn't Sendable, so it never leaves this actor.
actor WhisperKitEngine: SpeechToTextEngine {
    /// Whisper's prompt window is 224 tokens, and long prompts make it hallucinate.
    private static let maxPromptTokens = 200
    private static let languageCodes = Set(Constants.languages.values)

    private let model: DownloadedModel
    private var kit: WhisperKit?
    private var loading: Task<Void, any Error>?

    init(model: DownloadedModel) {
        self.model = model
    }

    func load(language: String) async throws {
        _ = try whisperLanguage(language)
        try await loadKit()
    }

    func transcribe(_ samples: [Float], language: String, prompt: String) async throws -> [EngineTranscription.Segment] {
        let code = try whisperLanguage(language)
        try await loadKit()
        guard let kit else { throw ModelError.modelFailed("\(model.name) was unloaded while transcribing") }
        guard !samples.isEmpty else { return [] }

        var options = DecodingOptions(
            language: code,
            usePrefillPrompt: true,
            detectLanguage: code == nil,
            skipSpecialTokens: true,
            // Word timings shift segment times (a 4.9 s clip came back as one 0.02–2.44 s segment).
            wordTimestamps: false
        )
        let hint = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty, let tokenizer = kit.tokenizer {
            let tokens = tokenizer.encode(text: " " + hint).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.promptTokens = Array(tokens.prefix(Self.maxPromptTokens))
        }

        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        } catch {
            throw ModelError.modelFailed("\(model.name) couldn't transcribe: \(error.localizedDescription)")
        }
        return results
            .flatMap(\.segments)
            // Whisper tends to invent text like "Thank you." on silence.
            .filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob < -1) }
            .map { EngineTranscription.Segment(start: Double($0.start), end: Double($0.end), text: $0.text) }
    }

    func unload() async {
        loading?.cancel()
        loading = nil
        await kit?.unloadModels()
        kit = nil
    }

    private func loadKit() async throws {
        if kit != nil { return }
        if let loading { return try await loading.value }
        let task = Task { try await self.createKit() }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func createKit() async throws {
        let config = WhisperKitConfig(
            modelFolder: model.folder.path,
            // The tokenizer is downloaded next to the model; WhisperKit would fetch it from the Hub otherwise.
            tokenizerFolder: model.folder,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        do {
            kit = try await WhisperKit(config)
        } catch {
            throw ModelError.modelFailed("\(model.name) couldn't be loaded: \(error.localizedDescription)")
        }
    }

    /// Whisper's language code for the language setting, or nil to detect it. Whisper silently returns
    /// nothing for a code it doesn't know, so those are rejected here.
    private func whisperLanguage(_ language: String) throws -> String? {
        guard let code = languageCode(language) else { return nil }
        guard Self.languageCodes.contains(code) else {
            throw ModelError.unsupportedLanguage("\(model.name) doesn't support \(languageName(code))")
        }
        return code
    }
}
