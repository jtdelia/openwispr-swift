import AVFoundation
import Foundation
import OpenWisprCore
import Speech

/// Apple's on-device `SpeechTranscriber`. Its language assets are downloaded on first use of a locale.
actor AppleSpeech: SpeechToTextEngine {
    private static let deniedReason =
        "Speech Recognition is turned off for OpenWispr. Turn it on in System Settings → Privacy & Security → Speech Recognition."
    private static let unavailableReason = "Apple's speech-to-text isn't available on this Mac"

    private let requestsAuthorization: Bool
    private let reportProgress: @Sendable (_ locale: String, _ fraction: Double) async -> Void
    private var supportedLocales: [Locale]?
    private var installs: [String: Task<Void, any Error>] = [:]

    /// macOS kills a process that asks for Speech Recognition without a usage description, as a
    /// command-line tool has none.
    init(requestsAuthorization: Bool, reportProgress: @escaping @Sendable (_ locale: String, _ fraction: Double) async -> Void) {
        self.requestsAuthorization = requestsAuthorization
        self.reportProgress = reportProgress
    }

    func status(language: String) async -> BuiltInStatus.AppleSpeech {
        guard SpeechTranscriber.isAvailable else {
            return BuiltInStatus.AppleSpeech(available: false, reason: Self.unavailableReason)
        }
        let locales = await locales().map { $0.identifier(.bcp47) }.sorted()
        let locale = await resolve(language)?.identifier(.bcp47)
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return BuiltInStatus.AppleSpeech(available: false, reason: Self.deniedReason, locale: locale, locales: locales)
        default:
            return BuiltInStatus.AppleSpeech(available: true, locale: locale, locales: locales)
        }
    }

    func load(language: String) async throws {
        let transcriber = try await prepare(language)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: Self.options)
        try await analyzer.prepareToAnalyze(in: Self.format())
        await analyzer.cancelAndFinishNow()
    }

    func transcribe(_ samples: [Float], language: String, prompt: String) async throws -> [EngineTranscription.Segment] {
        let transcriber = try await prepare(language)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format(), frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.int16ChannelData![0]
        for (index, sample) in samples.enumerated() {
            channel[index] = Int16(max(-1, min(1, sample)) * Float(Int16.max))
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: Self.options)
        let collector = Task {
            var segments: [EngineTranscription.Segment] = []
            for try await result in transcriber.results where result.isFinal {
                segments.append(.init(start: result.range.start.seconds, end: result.range.end.seconds, text: String(result.text.characters)))
            }
            return segments
        }
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    func unload() async {
        await SpeechModels.endRetention()
    }

    private static let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)

    /// The analyzer only accepts 16-bit samples; Float32 buffers crash the process.
    private static func format() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(speechSampleRate), channels: 1, interleaved: false)!
    }

    private func prepare(_ language: String) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw ModelError.unavailable(Self.unavailableReason) }
        try await authorize()
        guard let locale = await resolve(language) else {
            throw ModelError.unsupportedLanguage("Apple's speech-to-text doesn't support \(Self.languageName(language))")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await install(transcriber, locale: locale)
        return transcriber
    }

    /// Transcribing doesn't require it, but asking is what lists OpenWispr under Speech Recognition.
    private func authorize() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            guard requestsAuthorization else { return }
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            if status == .denied || status == .restricted { throw ModelError.unavailable(Self.deniedReason) }
        case .denied, .restricted:
            throw ModelError.unavailable(Self.deniedReason)
        @unknown default:
            return
        }
    }

    private func install(_ transcriber: SpeechTranscriber, locale: Locale) async throws {
        let id = locale.identifier(.bcp47)
        if let running = installs[id] { return try await running.value }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return
        case .unsupported: throw ModelError.unsupportedLanguage("Apple's speech-to-text doesn't support \(id) on this Mac")
        default: break
        }
        let report = reportProgress
        let task = Task {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
            let observation = request.progress.observe(\.fractionCompleted, options: [.initial]) { progress, _ in
                let fraction = progress.fractionCompleted
                Task { await report(id, fraction) }
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
            await report(id, 1)
        }
        installs[id] = task
        defer { installs[id] = nil }
        try await task.value
    }

    private func locales() async -> [Locale] {
        if let supportedLocales { return supportedLocales }
        let locales = await SpeechTranscriber.supportedLocales
        supportedLocales = locales
        return locales
    }

    /// Apple resolves bare language codes unpredictably (`en` became en-CA), so try the language with the
    /// Mac's region, then with the language's most likely region (`de` → de-DE), before asking Apple.
    private func resolve(_ language: String) async -> Locale? {
        let supported = await locales()
        let wanted = Self.wantedLocale(language)
        guard let code = wanted.language.languageCode else { return nil }
        let likelyRegion = Locale(identifier: Locale.Language(languageCode: code).maximalIdentifier).region
        for region in [wanted.region, likelyRegion].compactMap(\.self) {
            if let match = supported.first(where: { $0.language.languageCode == code && $0.region == region }) { return match }
        }
        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: wanted), equivalent.language.languageCode == code {
            return equivalent
        }
        return supported.first { $0.language.languageCode == code }
    }

    private static func wantedLocale(_ language: String) -> Locale {
        let trimmed = language.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return Locale(languageCode: Locale.current.language.languageCode, languageRegion: Locale.current.region)
        }
        if trimmed.contains("-") || trimmed.contains("_") { return Locale(identifier: trimmed) }
        return Locale(languageCode: Locale.LanguageCode(trimmed.lowercased()), languageRegion: Locale.current.region)
    }

    private static func languageName(_ language: String) -> String {
        OpenWisprEngines.languageName(wantedLocale(language).language.languageCode?.identifier ?? language)
    }
}
