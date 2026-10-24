import FluidAudio
import Foundation
import OpenWisprCore

/// Parakeet models loaded through FluidAudio, kept per folder so every request for a model shares one load.
/// The first load of a downloaded model compiles it for the Neural Engine, which takes about half a minute.
actor Parakeet {
    private var managers: [URL: Task<AsrManager, any Error>] = [:]

    func manager(for folder: URL) async throws -> AsrManager {
        if let loading = managers[folder] { return try await loading.value }
        let loading = Task {
            // `loadLocal`, unlike `load`, never reaches for the network.
            let models = try AsrModels.loadLocal(from: folder, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        managers[folder] = loading
        do {
            return try await loading.value
        } catch {
            if managers[folder] == loading { managers[folder] = nil }
            throw error
        }
    }

    func unload(_ folder: URL) async {
        guard let loading = managers.removeValue(forKey: folder), let manager = try? await loading.value else { return }
        await manager.cleanup()
    }

    func unloadAll() async {
        for folder in managers.keys { await unload(folder) }
    }
}

/// A downloaded Parakeet TDT v3 model. It detects the language itself; the language setting only steers it
/// away from words in another script.
struct ParakeetEngine: SpeechToTextEngine {
    /// From the model card. FluidAudio's script filter knows a few more, which the model wasn't trained on.
    static let supportedLanguages = parakeetLanguages
    /// Pauses longer than this start a new segment.
    private static let segmentGap: TimeInterval = 0.8

    let model: DownloadedModel
    let parakeet: Parakeet

    var languages: [String]? { Self.supportedLanguages }

    func load(language: String) async throws {
        _ = try hint(language)
        _ = try await parakeet.manager(for: model.folder)
    }

    /// Prompts are ignored: vocabulary hints need an extra model FluidAudio downloads separately.
    func transcribe(_ samples: [Float], language: String, prompt: String) async throws -> [EngineTranscription.Segment] {
        let hint = try hint(language)
        let manager = try await parakeet.manager(for: model.folder)
        guard samples.count >= ASRConstants.minimumRequiredSamples(forSampleRate: speechSampleRate) else { return [] }
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? [] : [.init(start: 0, end: result.duration, text: text)]
        }
        return Self.segments(timings)
    }

    func unload() async {
        await parakeet.unload(model.folder)
    }

    private func hint(_ language: String) throws -> Language? {
        guard let code = languageCode(language) else { return nil }
        guard Self.supportedLanguages.contains(code) else {
            throw ModelError.unsupportedLanguage("\(model.name) doesn't support \(languageName(code))")
        }
        return Language(rawValue: code)
    }

    /// Parakeet times subword tokens; a token starting with `▁` begins a word. Segments end at sentence
    /// punctuation or a pause, and keep their leading space so joining them gives the transcript.
    static func segments(_ tokens: [TokenTiming]) -> [EngineTranscription.Segment] {
        var segments: [EngineTranscription.Segment] = []
        var current: EngineTranscription.Segment?
        for token in tokens {
            let piece = token.token.replacingOccurrences(of: "▁", with: " ")
            if let open = current, token.startTime - open.end <= segmentGap {
                current = .init(start: open.start, end: token.endTime, text: open.text + piece)
            } else {
                if let open = current { segments.append(open) }
                current = .init(start: token.startTime, end: token.endTime, text: piece)
            }
            if let open = current, [".", "?", "!"].contains(where: open.text.hasSuffix) {
                segments.append(open)
                current = nil
            }
        }
        if let open = current { segments.append(open) }
        return segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
