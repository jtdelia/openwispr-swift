import Foundation

/// Whisper's audio front end: 25 ms windows every 10 ms, read in 30 s windows of 3000 frames.
public enum WhisperAudio {
    public static let fftSize = 400
    public static let hopLength = 160
    public static let windowSamples = 30 * speechSampleRate
    public static let windowFrames = windowSamples / hopLength
    /// Each timestamp token is 0.02 s: the encoder halves the frame rate.
    public static let secondsPerTimestamp = 0.02
    public static let framesPerTimestamp = 2
}

/// The special tokens of a Transformers Whisper checkpoint, read from its `generation_config.json`.
public struct WhisperVocabulary: Sendable, Equatable {
    public var endOfText: Int
    public var startOfTranscript: Int
    public var startOfPrevious: Int
    public var noTimestamps: Int
    /// nil for English-only models, which take no language or task token.
    public var transcribe: Int?
    /// Language code, like `en`, to its token.
    public var languages: [String: Int]
    public var suppressed: [Int]
    public var suppressedAtBegin: [Int]
    /// The first timestamp may be at most this many 0.02 s steps into the window.
    public var maxInitialTimestamp: Int

    public var timestampBegin: Int { noTimestamps + 1 }
    /// `<|nocaptions|>`, whose probability after the start token says the window holds no speech.
    public var noSpeech: Int { noTimestamps - 1 }
    public var isMultilingual: Bool { !languages.isEmpty }

    private struct Config: Decodable {
        var eosTokenId: Int
        var decoderStartTokenId: Int
        var prevSotTokenId: Int
        var noTimestampsTokenId: Int
        var langToId: [String: Int]?
        var taskToId: [String: Int]?
        var suppressTokens: [Int]?
        var beginSuppressTokens: [Int]?
        var maxInitialTimestampIndex: Int?
    }

    public init(generationConfig data: Data) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config = try decoder.decode(Config.self, from: data)
        endOfText = config.eosTokenId
        startOfTranscript = config.decoderStartTokenId
        startOfPrevious = config.prevSotTokenId
        noTimestamps = config.noTimestampsTokenId
        transcribe = config.taskToId?["transcribe"]
        languages = Dictionary(uniqueKeysWithValues: (config.langToId ?? [:]).map { (String($0.key.dropFirst(2).dropLast(2)), $0.value) })
        suppressed = config.suppressTokens ?? []
        suppressedAtBegin = config.beginSuppressTokens ?? []
        maxInitialTimestamp = config.maxInitialTimestampIndex ?? 50
    }

    /// What starts every window: the start token, then the language and task for multilingual models.
    public func startSequence(language: Int?) -> [Int] {
        guard isMultilingual, let transcribe, let language else { return [startOfTranscript] }
        return [startOfTranscript, language, transcribe]
    }
}

/// librosa's Slaney-style mel filterbank, as Whisper and Transformers compute it: `melCount` rows of
/// `fftSize / 2 + 1` weights, row-major.
public func whisperMelFilters(melCount: Int, fftSize: Int = WhisperAudio.fftSize, sampleRate: Int = speechSampleRate) -> [Float] {
    let bins = fftSize / 2 + 1
    let minLogHz = 1000.0
    let melPerHz = 3.0 / 200
    let minLogMel = minLogHz * melPerHz
    let logStep = log(6.4) / 27
    let toMel = { (hz: Double) in hz >= minLogHz ? minLogMel + log(hz / minLogHz) / logStep : hz * melPerHz }
    let toHz = { (mel: Double) in mel >= minLogMel ? minLogHz * exp(logStep * (mel - minLogMel)) : mel / melPerHz }
    let maxMel = toMel(Double(sampleRate) / 2)
    let edges = (0..<(melCount + 2)).map { toHz(maxMel * Double($0) / Double(melCount + 1)) }
    let frequencies = (0..<bins).map { Double(sampleRate) / 2 * Double($0) / Double(bins - 1) }
    var filters = [Float](repeating: 0, count: melCount * bins)
    for mel in 0..<melCount {
        let (low, center, high) = (edges[mel], edges[mel + 1], edges[mel + 2])
        let norm = 2 / (high - low)
        for bin in 0..<bins {
            let rising = (frequencies[bin] - low) / (center - low)
            let falling = (high - frequencies[bin]) / (high - center)
            filters[mel * bins + bin] = Float(max(0, min(rising, falling)) * norm)
        }
    }
    return filters
}

/// Greedy decoding with Whisper's rules: timestamps come in pairs and never go back, the window starts with
/// a timestamp, and a timestamp wins when all of them together are likelier than any text token.
/// `sampled` holds the tokens chosen since the start sequence. Returns the token and its log probability.
public func nextWhisperToken(_ logits: [Float], sampled: [Int], vocabulary: WhisperVocabulary) -> (token: Int, logProbability: Float) {
    var logits = logits
    let timestamps = vocabulary.timestampBegin..<logits.count
    func suppress(_ range: Range<Int>) {
        for token in range.clamped(to: 0..<logits.count) { logits[token] = -.infinity }
    }
    for token in vocabulary.suppressed where logits.indices.contains(token) { logits[token] = -.infinity }
    suppress((vocabulary.endOfText + 1)..<vocabulary.timestampBegin)
    if sampled.isEmpty {
        for token in vocabulary.suppressedAtBegin where logits.indices.contains(token) { logits[token] = -.infinity }
        suppress(0..<vocabulary.timestampBegin)
        suppress((vocabulary.timestampBegin + vocabulary.maxInitialTimestamp + 1)..<logits.count)
    }

    let lastWasTimestamp = sampled.last.map { $0 >= vocabulary.timestampBegin } ?? false
    let penultimateWasTimestamp = sampled.count < 2 || sampled[sampled.count - 2] >= vocabulary.timestampBegin
    if lastWasTimestamp {
        if penultimateWasTimestamp { suppress(timestamps) } else { suppress(0..<vocabulary.endOfText) }
    }
    if let last = sampled.last(where: { $0 >= vocabulary.timestampBegin }) {
        let closesSegment = lastWasTimestamp && !penultimateWasTimestamp
        suppress(vocabulary.timestampBegin..<(closesSegment ? last : last + 1))
    }

    var logProbabilities = logSoftmax(logits)
    let textBest = logProbabilities[..<vocabulary.timestampBegin].max() ?? -.infinity
    if logSumExp(logProbabilities[timestamps]) > textBest {
        suppress(0..<vocabulary.timestampBegin)
        logProbabilities = logSoftmax(logits)
    }
    let token = logProbabilities.indices.max { logProbabilities[$0] < logProbabilities[$1] } ?? vocabulary.endOfText
    return (token, logProbabilities[token])
}

/// A stretch of a window between two timestamps, in seconds from the window's start.
public struct WhisperSegment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// Text tokens only.
    public var tokens: [Int]

    public init(start: Double, end: Double, tokens: [Int]) {
        self.start = start
        self.end = end
        self.tokens = tokens
    }
}

/// Splits a window's tokens (without the end token) into segments at each pair of timestamps, and says how
/// many mel frames it used: up to the last complete segment, or all `frames` when the speech ran to its end.
public func splitWhisperWindow(_ tokens: [Int], vocabulary: WhisperVocabulary, frames: Int) -> (segments: [WhisperSegment], consumedFrames: Int) {
    let begin = vocabulary.timestampBegin
    let isTimestamp = tokens.map { $0 >= begin }
    let text = { (slice: ArraySlice<Int>) in slice.filter { $0 < vocabulary.endOfText } }
    let time = { (token: Int) in Double(token - begin) * WhisperAudio.secondsPerTimestamp }
    let endsWithSingleTimestamp = isTimestamp.count >= 2 && isTimestamp[isTimestamp.count - 1] && !isTimestamp[isTimestamp.count - 2]
    var cuts = isTimestamp.indices.dropFirst().filter { isTimestamp[$0 - 1] && isTimestamp[$0] }
    guard !cuts.isEmpty else {
        let duration = tokens.last(where: { $0 > begin }).map(time) ?? Double(frames * WhisperAudio.hopLength) / Double(speechSampleRate)
        let words = text(tokens[...])
        return (words.isEmpty ? [] : [WhisperSegment(start: 0, end: duration, tokens: words)], frames)
    }
    if endsWithSingleTimestamp { cuts.append(tokens.count) }
    var segments: [WhisperSegment] = []
    var start = 0
    for cut in cuts {
        let slice = tokens[start..<cut]
        let words = text(slice)
        if let first = slice.first, let last = slice.last, !words.isEmpty {
            segments.append(WhisperSegment(start: time(first), end: time(last), tokens: words))
        }
        start = cut
    }
    if endsWithSingleTimestamp { return (segments, frames) }
    return (segments, min(frames, (tokens[start - 1] - begin) * WhisperAudio.framesPerTimestamp))
}

private func logSoftmax(_ logits: [Float]) -> [Float] {
    let total = logSumExp(logits[...])
    return logits.map { $0 - total }
}

private func logSumExp(_ values: ArraySlice<Float>) -> Float {
    guard let top = values.max(), top > -.infinity else { return -.infinity }
    return top + log(values.reduce(0) { $0 + exp($1 - top) })
}
