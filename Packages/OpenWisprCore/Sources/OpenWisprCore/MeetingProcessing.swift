import Foundation

/// Roughly 50k tokens; longer transcripts keep their beginning and end, which carry intros and wrap-ups.
private let maxTranscriptChars = 200_000
private let titleMaxChars = 80

private func normalizeForComparison(_ text: String) -> String {
    text.lowercased().replacing(pattern: #"[^\p{L}\p{N}\s]"#, with: "").replacing(pattern: #"\s+"#, with: " ").trimmed
}

/// Whisper-family models invent these on near-silent audio (trained on subtitled video). A chunk whose
/// entire text is one of them is dropped. Plausible meeting phrases like "Thank you" are not listed.
private let hallucinations = Set([
    "you",
    "thanks for watching",
    "thank you for watching",
    "thank you so much for watching",
    "please subscribe",
    "like and subscribe",
    "subtitles by the amaraorg community",
].map(normalizeForComparison))

public func isLikelyHallucination(_ text: String) -> Bool {
    let normalized = normalizeForComparison(text)
    return normalized.isEmpty || hallucinations.contains(normalized)
}

/// One line per speaker turn, labelled with the names the user gave or the detected ones.
public func formatTranscript(_ entries: [TranscriptEntry], names: [String: String], userName: String) -> String {
    transcriptTurns(entries)
        .map { "[\(formatClock($0.startMs))] \(Speakers.label($0.speaker, names: names, userName: userName)): \($0.text.trimmed)" }
        .joined(separator: "\n")
}

/// For chat models of unknown context, which get the whole meeting in one request.
public func shortenTranscript(_ text: String) -> String {
    if text.utf16Length <= maxTranscriptChars { return text }
    let half = maxTranscriptChars / 2
    return "\(text.jsSlice(0, half))\n[… middle of the meeting omitted for length …]\n\(text.jsSlice(-half))"
}

public struct SpeakerRename: Sendable, Equatable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Rewrites speaker labels in an existing summary after the user renames speakers, e.g. "Speaker 2" → "Dana".
public func relabelSummary(_ summary: String, renames: [SpeakerRename]) -> String {
    let changed = renames.filter { !$0.from.isEmpty && !$0.to.isEmpty && $0.from != $0.to }.sorted { $0.from.utf16Length > $1.from.utf16Length }
    if changed.isEmpty { return summary }
    let pattern = "(?<![\\p{L}\\p{N}])(\(changed.map { escapeRegex($0.from) }.joined(separator: "|")))(?![\\p{L}\\p{N}])"
    let to = Dictionary(changed.map { ($0.from, $0.to) }, uniquingKeysWith: { first, _ in first })
    return summary.replacing(pattern: pattern) { groups in
        let match = groups[0] ?? ""
        return to[match] ?? match
    }
}

/// Whisper's prompt conditions spelling and continuity; the previous text of the same speaker helps both.
public func chunkPrompt(vocabularyPrompt: String, previousText: String) -> String {
    let tail = previousText.jsSlice(-400).trimmed
    return [vocabularyPrompt, tail].filter { !$0.isEmpty }.joined(separator: " ")
}

public func titleMessages(transcript: String, notes: String) -> [ChatMessage] {
    let system = [
        "You name meetings. Read the meeting transcript and the attendee notes and reply with a concise 3-6 word title for the meeting.",
        "The transcript is the primary grounding; the notes are secondary context. Do not copy a sentence verbatim.",
        "Output only the title: no quotes, no trailing punctuation, no prefix such as \"Title:\".",
    ].joined(separator: "\n")
    let user = [
        transcript.isEmpty ? "" : "<transcript>\n\(transcript)\n</transcript>",
        notes.trimmed.isEmpty ? "" : "<notes>\n\(notes.trimmed)\n</notes>",
    ].filter { !$0.isEmpty }.joined(separator: "\n")
    return [.system(system), .user(user)]
}

public func sanitizeTitle(_ output: String) -> String {
    let firstLine = output.trimmed.components(separatedBy: "\n").first ?? ""
    let title = firstLine
        .replacing(pattern: #"^(title|meeting title)\s*:\s*"#, with: "", caseInsensitive: true)
        .replacing(pattern: #"^["'“‘*#\s]+|["'”’*\s]+$"#, with: "")
        .replacing(pattern: #"[.!?;:,]+$"#, with: "")
        .trimmed
    return title.utf16Length > titleMaxChars ? "\(title.jsSlice(0, titleMaxChars - 1).trimmedEnd)…" : title
}

public struct SummaryInput: Sendable, Equatable {
    public var title: String
    public var transcript: String
    public var notes: String
    public var userName: String
    public var dictionary: [DictionaryEntry]
    /// Epoch ms.
    public var recordedAt: Double

    public init(title: String, transcript: String, notes: String, userName: String, dictionary: [DictionaryEntry], recordedAt: Double) {
        self.title = title
        self.transcript = transcript
        self.notes = notes
        self.userName = userName
        self.dictionary = dictionary
        self.recordedAt = recordedAt
    }
}

private func spellingRule(_ dictionary: [DictionaryEntry]) -> [String] {
    let spellings = dictionary.map(\.word.trimmed).filter { !$0.isEmpty }
    return spellings.isEmpty ? [] : ["- Always use these exact spellings: \(spellings.joined(separator: ", "))."]
}

private func formatParts(_ parts: [String]) -> String {
    "<parts>\n\(parts.enumerated().map { "Part \($0.offset + 1):\n\($0.element.trimmed)" }.joined(separator: "\n\n"))\n</parts>"
}

private let meetingDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateStyle = .full
    formatter.timeStyle = .short
    return formatter
}()

/// The meeting notes, from the transcript or, for a meeting too long for the chat model, from `parts`:
/// summaries of its consecutive sections, in order.
public func summaryMessages(_ input: SummaryInput, parts: [String]? = nil) -> [ChatMessage] {
    let me = Speakers.defaultLabel(Speakers.you, userName: input.userName)
    let rules = [
        parts != nil
            ? "You are a meeting notetaker. You receive notes on consecutive parts of a long meeting's transcript, in order, and the user's own notes, and write the meeting notes in Markdown."
            : "You are a meeting notetaker. You receive a meeting transcript and the user's own notes, and write the meeting notes in Markdown.",
        "",
        "The transcript comes from two audio channels:",
        "- \"\(me)\" is the user, recorded from their microphone.",
        // swiftlint:disable:next line_length
        "- Everyone else on the call is recorded from the computer audio. A name means the meeting app showed that person talking, or the user named them. \"Speaker 1\", \"Speaker 2\", … are distinct voices whose names are unknown. \"Others\" is call audio that could not be attributed and may mix several people: tell them apart by context and use names when they are mentioned.",
        "The transcript is automatic speech recognition: expect misheard words and fix them when the context makes the intent clear.",
        "",
        "Write these sections, in this order, as `###` headings. Omit any section that would be empty:",
        "### Summary: two to four sentences on the purpose and outcome of the meeting.",
        "### Key points: bullets grouped by topic, using bold topic labels when there are several topics.",
        "### Decisions: bullets for what was agreed.",
        "### Action Items: one `- [ ]` checkbox per task, starting with the owner when known (e.g. `- [ ] **Sam**: send the deck`).",
        "",
        "Rules:",
        "- Output only the Markdown notes: no preamble and no closing remarks.",
        "- The user's notes show what mattered to them: make sure those topics are covered, but do not repeat the notes verbatim.",
        "- Be specific: keep names, numbers, dates and commitments. Leave out small talk and filler.",
        "- Never invent facts that are not supported by the transcript or notes.",
        "- Write in the language the meeting was held in.",
    ] + spellingRule(input.dictionary)

    let title = input.title.trimmed
    let notes = input.notes.trimmed
    let user = [
        "<meeting>",
        "Title: \(title.isEmpty ? "(untitled)" : title)",
        "Date: \(meetingDateFormatter.string(from: Date(timeIntervalSince1970: input.recordedAt / 1000)))",
        "</meeting>",
        "<notes>\n\(notes.isEmpty ? "(none)" : notes)\n</notes>",
        parts.map(formatParts) ?? "<transcript>\n\(input.transcript)\n</transcript>",
    ].joined(separator: "\n")
    return [.system(rules.joined(separator: "\n")), .user(user)]
}

/// Notes on one section of a meeting too long for the chat model, to be combined by `summaryMessages`.
public func sectionMessages(userName: String, dictionary: [DictionaryEntry], section: String) -> [ChatMessage] {
    let me = Speakers.defaultLabel(Speakers.you, userName: userName)
    let rules = [
        "You take notes on one part of a long meeting, to be combined into the meeting notes later.",
        "\"\(me)\" is the user. Other names are call participants, \"Speaker 1\", \"Speaker 2\", … are voices whose names are unknown, and \"Others\" is call audio that could not be attributed.",
        "The transcript is automatic speech recognition: fix misheard words when the context makes the intent clear.",
        "",
        "Rules:",
        "- Write short Markdown bullets: the topics discussed, what was decided, and every task with its owner.",
        "- Keep names, numbers, dates and commitments. Leave out small talk and filler.",
        "- Output only the bullets. Never invent facts.",
        "- Write in the language the meeting was held in.",
    ] + spellingRule(dictionary)
    return [.system(rules.joined(separator: "\n")), .user("<transcript>\n\(section)\n</transcript>")]
}

/// Merges notes on consecutive sections when there are too many to combine at once.
public func mergeMessages(dictionary: [DictionaryEntry], parts: [String]) -> [ChatMessage] {
    let rules = [
        "You merge notes on consecutive parts of a long meeting into one shorter set of notes, to be combined into the meeting notes later.",
        "",
        "Rules:",
        "- Keep every decision and every task with its owner, and keep names, numbers and dates. Merge points that repeat.",
        "- Output only Markdown bullets. Never invent facts.",
        "- Write in the language of the notes.",
    ] + spellingRule(dictionary)
    return [.system(rules.joined(separator: "\n")), .user(formatParts(parts))]
}

/// Some models wrap the whole answer in a fenced Markdown block.
public func sanitizeSummary(_ output: String) -> String {
    let text = output.trimmed
    guard let match = text.firstMatch(#"(?is)^```(?:markdown|md)?\s*\n(.*?)\n```$"#), let inner = match[1] else { return text }
    return inner.trimmed
}
