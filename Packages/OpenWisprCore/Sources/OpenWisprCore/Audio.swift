import Foundation

/// Every recording OpenWispr transcribes is 16 kHz mono.
public let speechSampleRate = 16_000

/// 16-bit PCM mono WAV.
public func encodeWav(samples: [Float], sampleRate: Int = speechSampleRate) -> Data {
    var data = Data(capacity: 44 + samples.count * 2)
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + samples.count * 2))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * 2))
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(samples.count * 2))
    for sample in samples {
        let clamped = max(-1, min(1, sample))
        append(Int16(clamped < 0 ? clamped * 0x8000 : clamped * 0x7FFF))
    }
    return data
}

public struct DecodedAudio: Sendable, Equatable {
    public var samples: [Float]
    public var sampleRate: Int

    public var durationMs: Double { Double(samples.count) / Double(sampleRate) * 1000 }
}

/// Reads a 16-bit PCM WAV, mixing channels down to mono.
public func decodeWav(_ data: Data) throws -> DecodedAudio {
    let bytes = [UInt8](data)
    func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8) else {
        throw AppError("Not a WAV file")
    }
    var offset = 12
    var channels = 0
    var sampleRate = 0
    var bits = 0
    while offset + 8 <= bytes.count {
        let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
        let size = u32(offset + 4)
        let body = offset + 8
        if id == "fmt " {
            guard u16(body) == 1 else { throw AppError("Only PCM WAV files are supported") }
            channels = u16(body + 2)
            sampleRate = u32(body + 4)
            bits = u16(body + 14)
        } else if id == "data" {
            guard bits == 16, channels > 0 else { throw AppError("Only 16-bit WAV files are supported") }
            let end = min(bytes.count, body + size)
            let frames = (end - body) / (2 * channels)
            var samples = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    let at = body + (frame * channels + channel) * 2
                    sum += Float(Int16(bitPattern: UInt16(u16(at)))) / 32768
                }
                samples[frame] = sum / Float(channels)
            }
            return DecodedAudio(samples: samples, sampleRate: sampleRate)
        }
        offset = body + size + (size & 1)
    }
    throw AppError("The WAV file has no audio")
}

/// Bytes of a WAV holding `ms` of 16 kHz mono PCM16.
public func wavBytes(ms: Double) -> Int { 44 + Int(Double(speechSampleRate * 2) * ms / 1000) }

public func msToSamples(_ ms: Double, sampleRate: Int) -> Int {
    Int((ms / 1000 * Double(sampleRate)).rounded())
}

public func rms<C: Collection>(_ frame: C) -> Float where C.Element == Float {
    guard !frame.isEmpty else { return 0 }
    var sum: Float = 0
    for sample in frame { sum += sample * sample }
    return (sum / Float(frame.count)).squareRoot()
}

public let speechThreshold: Float = 0.01
public let minSpeechMs = 400.0
private let speechFrame = 1024

/// Milliseconds of `samples` whose frames are loud enough to count as speech.
public func speechMs(_ samples: [Float], sampleRate: Int, threshold: Float = speechThreshold) -> Double {
    var speech = 0
    var at = 0
    while at < samples.count {
        let frame = samples[at..<min(samples.count, at + speechFrame)]
        if rms(frame) >= threshold { speech += frame.count }
        at += speechFrame
    }
    return Double(speech) / Double(sampleRate) * 1000
}

public struct SpeechChunk: Sendable, Equatable {
    public var samples: [Float]
    public var startSample: Int
    public var endSample: Int
}

public struct ChunkerOptions: Sendable {
    public var sampleRate: Int
    /// RMS above which a frame counts as speech.
    public var speechThreshold: Float = OpenWisprCore.speechThreshold
    /// Cut at the first pause after this much audio.
    public var minChunkMs = 6000.0
    /// Cut regardless of pauses after this much audio, to keep the live transcript moving.
    public var maxChunkMs = 25_000.0
    /// Silence that counts as a pause.
    public var pauseMs = 600.0
    /// Silence kept before the first speech frame of a chunk.
    public var prerollMs = 300.0
    /// Chunks with less speech than this are dropped; they make Whisper hallucinate.
    public var minSpeechMs = OpenWisprCore.minSpeechMs
    /// After `requestCut`: the shortest chunk and pause to cut at, since turn-taking leaves short gaps.
    public var requestedCutMinMs = 1000.0
    public var requestedCutPauseMs = 250.0

    public init(sampleRate: Int) { self.sampleRate = sampleRate }
}

/// Splits a continuous audio stream into utterance-sized chunks at pauses, so each one can be sent to a
/// batch transcription endpoint while the meeting is still going.
public struct SpeechChunker: Sendable {
    private let sampleRate: Int
    private let threshold: Float
    private let minChunkSamples: Int
    private let maxChunkSamples: Int
    private let pauseSamples: Int
    private let prerollSamples: Int
    private let minSpeechSamples: Int
    private let requestedCutMinSamples: Int
    private let requestedCutPauseSamples: Int

    private var frames: [[Float]] = []
    private var length = 0
    private var startSample = 0
    private var speechSamples = 0
    private var trailingSilence = 0
    private var totalSamples = 0
    private var cutRequested = false

    public init(_ options: ChunkerOptions) {
        let ms = { (value: Double) in msToSamples(value, sampleRate: options.sampleRate) }
        sampleRate = options.sampleRate
        threshold = options.speechThreshold
        minChunkSamples = ms(options.minChunkMs)
        maxChunkSamples = ms(options.maxChunkMs)
        pauseSamples = ms(options.pauseMs)
        prerollSamples = ms(options.prerollMs)
        minSpeechSamples = ms(options.minSpeechMs)
        requestedCutMinSamples = ms(options.requestedCutMinMs)
        requestedCutPauseSamples = ms(options.requestedCutPauseMs)
    }

    /// Feeds one frame of audio; returns a chunk when this frame completes one.
    public mutating func push(_ frame: [Float]) -> SpeechChunk? {
        let speech = rms(frame) >= threshold
        frames.append(frame)
        length += frame.count
        totalSamples += frame.count
        if speech {
            speechSamples += frame.count
            trailingSilence = 0
        } else {
            trailingSilence += frame.count
        }
        if speechSamples == 0 {
            trimPreroll()
            return nil
        }
        let paused = cutRequested
            ? length >= requestedCutMinSamples && trailingSilence >= requestedCutPauseSamples
            : length >= minChunkSamples && trailingSilence >= pauseSamples
        return paused || length >= maxChunkSamples ? cut() : nil
    }

    /// Ends the current chunk at the next short pause, e.g. when someone else starts talking.
    public mutating func requestCut() {
        if speechSamples > 0 { cutRequested = true }
    }

    /// Returns whatever speech is buffered, e.g. when recording stops.
    public mutating func flush() -> SpeechChunk? { cut() }

    public func msAt(_ sample: Int) -> Double {
        (Double(sample) / Double(sampleRate) * 1000).rounded()
    }

    private mutating func trimPreroll() {
        while frames.count > 1, length - frames[0].count >= prerollSamples {
            let dropped = frames.removeFirst()
            length -= dropped.count
            startSample += dropped.count
        }
    }

    private mutating func cut() -> SpeechChunk? {
        let chunk = speechSamples >= minSpeechSamples
            ? SpeechChunk(samples: Array(frames.joined()), startSample: startSample, endSample: totalSamples)
            : nil
        frames = []
        length = 0
        startSample = totalSamples
        speechSamples = 0
        trailingSilence = 0
        cutRequested = false
        return chunk
    }
}
