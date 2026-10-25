import Foundation
import Testing
@testable import OpenWisprCore

/// openai/whisper-small.en's layout, trimmed: 51864 tokens, timestamps from 50363.
private let englishConfig = #"""
{"eos_token_id":50256,"decoder_start_token_id":50257,"prev_sot_token_id":50360,"no_timestamps_token_id":50362,
 "suppress_tokens":[1,2,7],"begin_suppress_tokens":[220,50256],"max_initial_timestamp_index":50,"is_multilingual":false}
"""#
private let multilingualConfig = #"""
{"eos_token_id":50257,"decoder_start_token_id":50258,"prev_sot_token_id":50361,"no_timestamps_token_id":50363,
 "lang_to_id":{"<|en|>":50259,"<|de|>":50261,"<|haw|>":50352},"task_to_id":{"transcribe":50359,"translate":50358},
 "suppress_tokens":[1],"begin_suppress_tokens":[220,50257],"is_multilingual":true}
"""#
private let english = try! WhisperVocabulary(generationConfig: Data(englishConfig.utf8))
private let vocabularySize = 51864
private let begin = english.timestampBegin

/// Logits that favor `token`, with every other token equally likely.
private func logits(favoring token: Int, by margin: Float = 10) -> [Float] {
    var logits = [Float](repeating: 0, count: vocabularySize)
    logits[token] = margin
    return logits
}

@Suite("Reading a Whisper checkpoint's special tokens")
struct WhisperVocabularyTests {
    @Test func `an English-only model starts each window with the start token alone`() {
        #expect(!english.isMultilingual)
        #expect(english.timestampBegin == 50363 && english.noSpeech == 50361)
        #expect(english.startSequence(language: nil) == [50257])
        #expect(english.maxInitialTimestamp == 50)
    }

    @Test func `a multilingual model adds the language and task, and knows its languages by code`() throws {
        let vocabulary = try WhisperVocabulary(generationConfig: Data(multilingualConfig.utf8))
        #expect(vocabulary.isMultilingual)
        #expect(vocabulary.languages == ["en": 50259, "de": 50261, "haw": 50352])
        #expect(vocabulary.startSequence(language: 50261) == [50258, 50261, 50359])
        #expect(vocabulary.maxInitialTimestamp == 50)
    }

    @Test func `a config without Whisper's tokens is refused`() {
        #expect(throws: (any Error).self) { try WhisperVocabulary(generationConfig: Data(#"{"eos_token_id":2}"#.utf8)) }
    }
}

@Suite("Whisper's mel filterbank")
struct WhisperMelFilterTests {
    /// Reference values from the `mel_filters` openai/whisper-small.en ships in preprocessor_config.json.
    @Test func `matches the filters OpenAI ships`() {
        let filters = whisperMelFilters(melCount: 80)
        let bins = 201
        #expect(filters.count == 80 * bins)
        let expected: [(mel: Int, bin: Int, value: Float)] = [
            (0, 1, 0.024862595), (1, 1, 0.0019908219), (1, 2, 0.022871772),
            (40, 42, 0.0054111048), (40, 43, 0.014735566), (40, 44, 0.0065181898),
            (79, 186, 0.00036674167), (79, 188, 0.0012993984),
        ]
        for (mel, bin, value) in expected {
            #expect(abs(filters[mel * bins + bin] - value) < 1e-6, "mel \(mel), bin \(bin)")
        }
        let nonZero = [0, 1, 40, 79].map { mel in filters[(mel * bins)..<((mel + 1) * bins)].filter { $0 > 0 }.count }
        #expect(nonZero == [1, 2, 3, 14])
    }

    @Test func `has a row per mel band for large-v3’s 128`() {
        #expect(whisperMelFilters(melCount: 128).count == 128 * 201)
    }
}

@Suite("Choosing Whisper's next token")
struct WhisperNextTokenTests {
    @Test func `starts a window with a timestamp, even when text looks likelier`() {
        let (token, _) = nextWhisperToken(logits(favoring: 400), sampled: [], vocabulary: english)
        #expect(token >= begin && token <= begin + 50)
    }

    @Test func `never starts later than the initial timestamp limit`() {
        let (token, _) = nextWhisperToken(logits(favoring: begin + 300), sampled: [], vocabulary: english)
        #expect(token <= begin + 50)
    }

    @Test func `follows an opening timestamp with text, not a second timestamp`() {
        let (token, _) = nextWhisperToken(logits(favoring: begin + 10), sampled: [begin], vocabulary: english)
        #expect(token < english.endOfText)
    }

    @Test func `closes a segment with a timestamp or the end, never text, after text then a timestamp`() {
        let (token, _) = nextWhisperToken(logits(favoring: 400), sampled: [begin, 400, begin + 20], vocabulary: english)
        #expect(token >= begin || token == english.endOfText)
    }

    @Test func `keeps timestamps from going back in time`() {
        var scores = logits(favoring: begin + 5, by: 30)
        scores[begin + 40] = 20
        let (token, _) = nextWhisperToken(scores, sampled: [begin, 400, begin + 30, begin + 30, 401], vocabulary: english)
        #expect(token == begin + 40)
    }

    @Test func `picks a timestamp when all timestamps together outweigh the best text token`() {
        var scores = [Float](repeating: -20, count: vocabularySize)
        for token in begin..<vocabularySize { scores[token] = 0 }
        scores[400] = 5
        let (token, _) = nextWhisperToken(scores, sampled: [begin, 400], vocabulary: english)
        #expect(token >= begin)
    }

    @Test func `never picks the suppressed or special tokens`() {
        for suppressed in [1, english.startOfTranscript, english.startOfPrevious, english.noTimestamps] {
            let (token, _) = nextWhisperToken(logits(favoring: suppressed, by: 50), sampled: [begin], vocabulary: english)
            #expect(token != suppressed)
        }
    }

    @Test func `reports the chosen token’s log probability`() {
        let (token, logProbability) = nextWhisperToken(logits(favoring: 400, by: 50), sampled: [begin], vocabulary: english)
        #expect(token == 400)
        #expect(logProbability > -0.001 && logProbability <= 0)
    }
}

@Suite("Splitting a Whisper window into segments")
struct WhisperWindowTests {
    let frames = WhisperAudio.windowFrames

    @Test func `cuts at each pair of timestamps and resumes after the last complete segment`() {
        let tokens = [begin, 10, 11, begin + 100, begin + 100, 12, begin + 250, begin + 260, 13]
        let (segments, consumed) = splitWhisperWindow(tokens, vocabulary: english, frames: frames)
        #expect(segments == [
            WhisperSegment(start: 0, end: 2, tokens: [10, 11]),
            WhisperSegment(start: 2, end: 5, tokens: [12]),
        ])
        #expect(consumed == 250 * 2)
    }

    @Test func `uses the whole window when its speech runs to a single closing timestamp`() {
        let tokens = [begin, 10, begin + 100, begin + 100, 12, begin + 250]
        let (segments, consumed) = splitWhisperWindow(tokens, vocabulary: english, frames: 1200)
        #expect(segments == [
            WhisperSegment(start: 0, end: 2, tokens: [10]),
            WhisperSegment(start: 2, end: 5, tokens: [12]),
        ])
        #expect(consumed == 1200)
    }

    @Test func `makes one segment up to the last timestamp when no pair cuts it`() {
        let (segments, consumed) = splitWhisperWindow([begin, 10, 11, begin + 150], vocabulary: english, frames: 900)
        #expect(segments == [WhisperSegment(start: 0, end: 3, tokens: [10, 11])])
        #expect(consumed == 900)
    }

    @Test func `spans the audio it read when there are no timestamps at all`() {
        let (segments, consumed) = splitWhisperWindow([10, 11], vocabulary: english, frames: 450)
        #expect(segments == [WhisperSegment(start: 0, end: 4.5, tokens: [10, 11])])
        #expect(consumed == 450)
    }

    @Test func `drops a segment without text`() {
        let (segments, _) = splitWhisperWindow([begin, begin + 50, begin + 50, 10, begin + 90], vocabulary: english, frames: frames)
        #expect(segments == [WhisperSegment(start: 1, end: 1.8, tokens: [10])])
    }
}
