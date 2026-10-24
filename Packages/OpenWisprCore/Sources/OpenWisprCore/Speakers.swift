import Foundation

/// Speaker keys identify who said a transcript entry:
/// - `you`: the user's microphone.
/// - `app:<name>`: a participant the meeting app showed as talking.
/// - `voice:<n>`: a distinct voice on the call audio, told apart by diarization.
/// - `others`: call audio nobody could be attributed to.
public enum Speakers {
    public static let you = "you"
    public static let others = "others"

    public static func app(_ name: String) -> String { "app:\(name)" }
    public static func voice(_ id: Int) -> String { "voice:\(id)" }

    public static func voiceId(_ key: String) -> Int? {
        key.firstMatch(#"^voice:(\d+)$"#)?[1].flatMap { Int($0) }
    }

    public static func key(_ entry: TranscriptEntry) -> String {
        entry.source == .mic ? you : (entry.speaker ?? others)
    }

    public static func defaultLabel(_ key: String, userName: String) -> String {
        if key == you { return userName.trimmed.isEmpty ? "Me" : "\(userName.trimmed) (me)" }
        if key.hasPrefix("app:") { return String(key.dropFirst("app:".count)) }
        return voiceId(key).map { "Speaker \($0)" } ?? "Others"
    }

    public static func label(_ key: String, names: [String: String], userName: String) -> String {
        if let name = names[key]?.trimmed, !name.isEmpty { return name }
        return defaultLabel(key, userName: userName)
    }
}

public struct TranscriptTurn: Sendable, Equatable, Identifiable {
    public var id: String
    public var speaker: String
    public var startMs: Double
    public var text: String
}

/// Consecutive entries from the same speaker merged into one turn, without microphone echoes.
public func transcriptTurns(_ entries: [TranscriptEntry]) -> [TranscriptTurn] {
    var turns: [TranscriptTurn] = []
    for entry in withoutEchoes(entries) {
        let speaker = Speakers.key(entry)
        if let last = turns.last, last.speaker == speaker {
            turns[turns.count - 1].text += " \(entry.text)"
        } else {
            turns.append(TranscriptTurn(id: entry.id, speaker: speaker, startMs: entry.startMs, text: entry.text))
        }
    }
    return turns
}

private let echoWindowMs = 3000.0
private let echoMinWords = 3
private let echoOverlap = 0.7

private func words(_ text: String) -> [String] {
    text.lowercased().replacing(pattern: #"[^\p{L}\p{N}\s]"#, with: "").split(whereSeparator: \.isWhitespace).map(String.init)
}

/// Drops microphone entries that repeat what the call audio said at the same time: speakers playing into
/// an open microphone, which echo cancellation does not always remove.
public func withoutEchoes(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
    let system = entries.filter { $0.source == .system }
    if system.isEmpty { return entries }
    return entries.filter { entry in
        if entry.source != .mic { return true }
        let mine = words(entry.text)
        if mine.count < echoMinWords { return true }
        let heard = Set(system.filter { $0.startMs < entry.endMs + echoWindowMs && $0.endMs > entry.startMs - echoWindowMs }.flatMap { words($0.text) })
        let repeated = mine.filter { heard.contains($0) }.count
        return Double(repeated) / Double(mine.count) < echoOverlap
    }
}

/// Counts per name, in the order names were first seen, so ties sort the way they did in the TypeScript app.
struct Tally<Value: AdditiveArithmetic & Comparable> {
    private(set) var entries: [(name: String, value: Value)] = []

    subscript(name: String) -> Value {
        entries.first { $0.name == name }?.value ?? .zero
    }

    mutating func add(_ name: String, _ amount: Value) {
        if let index = entries.firstIndex(where: { $0.name == name }) {
            entries[index].value += amount
        } else {
            entries.append((name, amount))
        }
    }

    /// Largest first; stable for equal values.
    var descending: [(name: String, value: Value)] {
        entries.enumerated().sorted { a, b in a.element.value != b.element.value ? a.element.value > b.element.value : a.offset < b.offset }.map(\.element)
    }
}

public struct IdentityConfig: Sendable {
    /// Sightings of the same name before a voice takes it.
    public var promoteThreshold = 3
    /// Sightings of a different name before a named voice switches to it.
    public var remapThreshold = 5
    public var remapCooldownMs = 30_000.0

    public init() {}
}

/// Ties diarized voices to the names the meeting app shows. A voice is named once the app has shown the
/// same person talking over it a few times, and keeps that name through segments where the app showed
/// nobody, so one stale or missed indicator does not relabel a voice.
public final class SpeakerIdentityMap {
    private struct Entry {
        var candidateName: String?
        var candidateCount = 0
        var canonicalName: String?
        var conflictName: String?
        var conflictCount = 0
        var lastRemapAt: Double?
    }

    private let config: IdentityConfig
    private var entries: [String: Entry] = [:]

    public init(config: IdentityConfig = IdentityConfig()) { self.config = config }

    /// The name for `voice` after this segment, given who the meeting app showed talking (if anyone).
    public func resolve(_ voice: String, observedName: String?, nowMs: Double) -> String? {
        var entry = entries[voice] ?? Entry()
        defer { entries[voice] = entry }
        guard let name = observedName?.trimmed, !name.isEmpty else { return entry.canonicalName }
        if entry.canonicalName == name {
            entry.conflictName = nil
            entry.conflictCount = 0
            return name
        }
        if let canonical = entry.canonicalName {
            if let last = entry.lastRemapAt, nowMs - last < config.remapCooldownMs { return canonical }
            entry.conflictCount = entry.conflictName == name ? entry.conflictCount + 1 : 1
            entry.conflictName = name
            if entry.conflictCount < config.remapThreshold { return canonical }
            entry = Entry(candidateName: name, candidateCount: entry.candidateCount, canonicalName: name, lastRemapAt: nowMs)
            return name
        }
        entry.candidateCount = entry.candidateName == name ? entry.candidateCount + 1 : 1
        entry.candidateName = name
        if entry.candidateCount < config.promoteThreshold { return nil }
        entry.canonicalName = name
        return name
    }
}

public struct SpeakerObservation: Sendable, Equatable {
    /// Epoch ms. Each observation holds until the next one.
    public var at: Double
    public var speaking: [String]

    public init(at: Double, speaking: [String]) {
        self.at = at
        self.speaking = speaking
    }
}

/// Share of a segment someone must be shown talking for to be credited with it.
private let minCoverage = 0.3
/// The runner-up must be well behind, or the segment is a mix of voices.
private let maxRunnerUp = 0.5

public struct CallCredit: Sendable, Equatable {
    public var name: String
    /// False when the segment was a mix of voices and a tie-break picked the name.
    public var clear: Bool
}

public struct OverlapHints {
    /// Never credited, e.g. the user, whose voice doesn't come back through the call audio.
    public var ignore: [String]
    /// Who the call audio was last credited to; people talking over them rarely take the call audio.
    public var previous: String?
    public var isRemote: (String) -> Bool

    public init(ignore: [String], previous: String?, isRemote: @escaping (String) -> Bool) {
        self.ignore = ignore
        self.previous = previous
        self.isRemote = isRemote
    }
}

/// Who the meeting app showed as talking over time, to credit call-audio segments to people.
public final class SpeakerTimeline {
    private var observations: [SpeakerObservation] = []

    public init() {}

    public func push(_ observation: SpeakerObservation) {
        if let last = observations.last, observation.at < last.at { return }
        observations.append(observation)
    }

    /// The person shown talking for most of `[from, to)`, or nil if nobody clearly was.
    public func dominant(_ from: Double, _ to: Double, ignore: [String] = []) -> String? {
        let ranked = coverage(from, to, ignore: ignore)
        guard let first = ranked.first, first.value >= minCoverage * (to - from) else { return nil }
        if ranked.count > 1, ranked[1].value > maxRunnerUp * first.value { return nil }
        return first.name
    }

    /// Credits a call-audio segment. When several people were shown talking through it, the one the call
    /// audio already belonged to keeps it, else the only one already confirmed as a remote voice.
    public func credit(_ from: Double, _ to: Double, hints: OverlapHints) -> CallCredit? {
        if let clear = dominant(from, to, ignore: hints.ignore) { return CallCredit(name: clear, clear: true) }
        let candidates = coverage(from, to, ignore: hints.ignore).filter { $0.value >= minCoverage * (to - from) }.map(\.name)
        if let previous = hints.previous, candidates.contains(previous) { return CallCredit(name: previous, clear: false) }
        let remote = candidates.filter(hints.isRemote)
        return remote.count == 1 ? CallCredit(name: remote[0], clear: false) : nil
    }

    /// Ms each person was shown talking within `[from, to)`, most first.
    private func coverage(_ from: Double, _ to: Double, ignore: [String]) -> [(name: String, value: Double)] {
        if to <= from { return [] }
        var talking = Tally<Double>()
        for (i, observation) in observations.enumerated() {
            let end = i + 1 < observations.count ? observations[i + 1].at : .infinity
            let overlap = min(end, to) - max(observation.at, from)
            if overlap <= 0 { continue }
            for name in observation.speaking where !ignore.contains(name) { talking.add(name, overlap) }
        }
        return talking.descending
    }
}

/// Microphone segments a name must be shown talking through before it is taken to be the user.
private let selfMinVotes = 2
/// Call-audio segments a name must clearly own, and at least match its mic votes, to be ruled out as the user.
private let remoteMinCredits = 2

/// Learns which participant the user is: the one the meeting app shows talking while the microphone
/// picks up speech. Meeting apps show the user's own tile under their account name, and their voice
/// never comes back through the call audio, so that name must not be credited with call-audio segments.
public final class SelfName {
    private var votes = Tally<Int>()
    private var credits = Tally<Int>()

    public init() {}

    public func vote(_ name: String?) {
        if let name, !name.isEmpty { votes.add(name, 1) }
    }

    /// Records that the call audio clearly belonged to `name`.
    public func heardOnCall(_ name: String) {
        credits.add(name, 1)
    }

    public func isRemote(_ name: String) -> Bool {
        let count = credits[name]
        return count >= remoteMinCredits && count >= votes[name]
    }

    /// People heard through the call audio, so a mic segment they were shown talking in is still the user's.
    public var remoteNames: [String] { credits.entries.map(\.name).filter(isRemote) }

    public var current: String? {
        let ranked = votes.descending.filter { !isRemote($0.name) }
        guard let first = ranked.first, first.value >= selfMinVotes else { return nil }
        if ranked.count > 1, ranked[1].value * 2 > first.value { return nil }
        return first.name
    }
}

/// Mirrors the summary states Wispr Flow's meeting view renders.
public enum SummaryState: Sendable, Equatable {
    case notYetGeneratable
    case tooShort(noAudio: Bool)
    case readyToGenerate
    case generating
    case generated(summary: String)
    case updateAvailable(summary: String)
    case updating(summary: String)
    case failed(summary: String?, error: String)
}

/// Below this many transcribed words there is nothing worth summarizing.
public let minSummaryWords = 20

public func summaryState(_ meeting: Meeting, recording: Bool) -> SummaryState {
    let summary = meeting.summary
    if meeting.summaryGenerating { return summary.map { .updating(summary: $0) } ?? .generating }
    if let error = meeting.summaryError, !error.isEmpty { return .failed(summary: summary, error: error) }
    if let summary {
        return meeting.recordedMs > meeting.summaryRecordedMs && !recording ? .updateAvailable(summary: summary) : .generated(summary: summary)
    }
    if recording { return .notYetGeneratable }
    if meeting.transcriptWords < minSummaryWords { return .tooShort(noAudio: meeting.recordedMs == 0 || meeting.transcriptWords == 0) }
    return .readyToGenerate
}

/// `m:ss`, or `h:mm:ss` from one hour.
public func formatClock(_ ms: Double) -> String {
    let totalSeconds = max(0, Int((ms / 1000).rounded(.down)))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    let mm = hours > 0 ? String(format: "%02d", minutes) : String(minutes)
    let mmss = "\(mm):\(String(format: "%02d", seconds))"
    return hours > 0 ? "\(hours):\(mmss)" : mmss
}
