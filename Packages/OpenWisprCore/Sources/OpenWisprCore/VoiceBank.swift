import Foundation

private let wavHeaderBytes = 44
/// OpenAI accepts 2-10 s reference clips and up to four known speakers per request.
private let minReferenceMs = 2000.0
private let maxReferenceMs = 10_000.0
private let maxVoices = 4

/// Keeps diarized voices consistent across chunks. Each chunk is diarized on its own, so the model's
/// `A`/`B` labels restart every time; a clip of each new voice is sent back as a known speaker reference
/// with later chunks, which then come back labelled with that voice.
public final class VoiceBank {
    private struct Voice {
        var id: Int
        /// What the model calls this voice in `diarized_json` once it is a known speaker.
        var label: String
        var reference: String
    }

    private var voices: [Voice] = []
    private var nextId: Int

    public init(nextId: Int) { self.nextId = nextId }

    public func knownSpeakers() -> KnownSpeakers? {
        voices.isEmpty ? nil : KnownSpeakers(names: voices.map(\.label), references: voices.map(\.reference))
    }

    /// Maps each segment's label to a voice id. New labels become voices when there is room and a long
    /// enough segment to keep as their reference; otherwise they stay unattributed.
    public func assign(_ segments: [TranscriptSegment], wav: Data) -> [String: Int] {
        var ids = Dictionary(voices.map { ($0.label, $0.id) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        let labels = segments.compactMap(\.speaker).filter { seen.insert($0).inserted }
        for label in labels {
            if ids[label] != nil || voices.count >= maxVoices { continue }
            let longest = segments.filter { $0.speaker == label }.reduce(nil as TranscriptSegment?) { a, b in
                guard let a else { return b }
                return b.endMs - b.startMs > a.endMs - a.startMs ? b : a
            }
            guard let longest, longest.endMs - longest.startMs >= minReferenceMs else { continue }
            let id = nextId
            nextId += 1
            let end = min(longest.endMs, longest.startMs + maxReferenceMs)
            let reference = "data:audio/wav;base64,\(sliceWav(wav, startMs: longest.startMs, endMs: end).base64EncodedString())"
            voices.append(Voice(id: id, label: "speaker_\(id)", reference: reference))
            ids[label] = id
        }
        return ids
    }
}

/// Cuts `[startMs, endMs)` out of a 16-bit mono PCM WAV.
public func sliceWav(_ wav: Data, startMs: Double, endMs: Double) -> Data {
    let bytes = [UInt8](wav)
    guard bytes.count >= wavHeaderBytes else { return wav }
    let sampleRate = Int(bytes[24]) | Int(bytes[25]) << 8 | Int(bytes[26]) << 16 | Int(bytes[27]) << 24
    let dataLength = bytes.count - wavHeaderBytes
    let at = { (ms: Double) in max(0, min(dataLength, Int((ms / 1000 * Double(sampleRate)).rounded()) * 2)) }
    let from = at(startMs)
    let to = max(from, at(endMs))
    let pcm = bytes[(wavHeaderBytes + from)..<(wavHeaderBytes + to)]
    var header = Array(bytes[0..<wavHeaderBytes])
    func put(_ value: Int, at offset: Int) {
        for i in 0..<4 { header[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }
    put(36 + pcm.count, at: 4)
    put(pcm.count, at: 40)
    return Data(header + pcm)
}
