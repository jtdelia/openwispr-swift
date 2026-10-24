import Foundation

/// The chat model as the Notetaker uses it.
@MainActor
public protocol MeetingChat: AnyObject {
    func complete(_ messages: [ChatMessage], label: String, timeout: TimeInterval, maxTokens: Int) async throws -> String
    func chatContextSize() async -> Int?
}

extension Models: MeetingChat {}

/// Lower than real tokenizers give for most languages, so a request estimated to fit usually does.
private let charsPerToken = 3
/// A section the model still finds too long is split further, down to this size.
private let minSectionChars = 200
private let titleTokens = 64
private let titleTranscriptChars = 12_000

private func estimateTokens(_ messages: [ChatMessage]) -> Int {
    Int((Double(messages.reduce(0) { $0 + $1.content.utf16Length }) / Double(charsPerToken)).rounded(.up))
}

/// A quarter of the context, in characters.
private func notesBudget(_ contextSize: Int) -> Int {
    Int(Double(contextSize) / 4 * Double(charsPerToken))
}

private func isTooLong(_ error: any Error) -> Bool {
    if case .contextExceeded = error as? ModelError { return true }
    return false
}

/// Splits `text` into pieces of at most `max` characters, at whitespace where there is some.
func splitText(_ text: String, max: Int) -> [String] {
    var pieces: [String] = []
    var rest = text
    while rest.utf16Length > max {
        let space = rest.jsLastIndex(of: " ", from: max)
        let at = Double(space) > Double(max) / 2 ? space : max
        pieces.append(rest.jsSlice(0, at))
        rest = rest.jsSlice(at).trimmedStart
    }
    if !rest.isEmpty { pieces.append(rest) }
    return pieces
}

/// Packs whole lines into sections of at most `max` characters; longer lines are split.
func sections(_ text: String, max: Int) -> [String] {
    var result: [String] = []
    var current = ""
    for line in text.components(separatedBy: "\n").flatMap({ splitText($0, max: max) }) {
        if !current.isEmpty && current.utf16Length + 1 + line.utf16Length > max {
            result.append(current)
            current = ""
        }
        current = current.isEmpty ? line : "\(current)\n\(line)"
    }
    if !current.isEmpty { result.append(current) }
    return result
}

private func halve(_ section: String) -> (String, String) {
    let lines = section.components(separatedBy: "\n")
    if lines.count > 1 {
        let middle = (lines.count + 1) / 2
        return (lines[..<middle].joined(separator: "\n"), lines[middle...].joined(separator: "\n"))
    }
    let pieces = splitText(section, max: (section.utf16Length + 1) / 2)
    return (pieces.first ?? "", pieces.dropFirst().joined(separator: " "))
}

/// The meeting notes for `input`. When the transcript and notes don't fit the chat model's context,
/// consecutive sections of the transcript are summarized first, and those summaries are combined with
/// the user's notes. Endpoints report no context size and get the whole meeting in one request.
@MainActor
public func summarizeMeeting(_ chat: MeetingChat, _ input: SummaryInput, timeout: TimeInterval = EndpointClient.timeout) async throws -> String {
    guard let contextSize = await chat.chatContextSize() else {
        var shortened = input
        shortened.transcript = shortenTranscript(input.transcript)
        return sanitizeSummary(try await chat.complete(summaryMessages(shortened), label: "Summary", timeout: timeout, maxTokens: defaultMaxTokens))
    }
    return sanitizeSummary(try await PiecewiseSummary(chat: chat, input: input, contextSize: contextSize, timeout: timeout).run())
}

/// A title for the meeting, from the start of its transcript (where meetings say what they're about)
/// and the notes, cut to fit the chat model's context.
@MainActor
public func titleMeeting(_ chat: MeetingChat, transcript: String, notes: String) async throws -> String {
    var transcript = transcript
    var notes = notes
    if let contextSize = await chat.chatContextSize() {
        notes = notes.trimmed.jsSlice(0, notesBudget(contextSize))
        let overhead = estimateTokens(titleMessages(transcript: "", notes: notes))
        transcript = transcript.jsSlice(0, max(0, (contextSize - overhead - titleTokens) * charsPerToken))
    } else {
        transcript = transcript.jsSlice(0, titleTranscriptChars)
    }
    let output = try await chat.complete(titleMessages(transcript: transcript, notes: notes), label: "Title", timeout: EndpointClient.timeout, maxTokens: titleTokens)
    return sanitizeTitle(output)
}

@MainActor
private struct PiecewiseSummary {
    let chat: MeetingChat
    let input: SummaryInput
    let contextSize: Int
    let timeout: TimeInterval
    let answerTokens: Int
    let partTokens: Int
    /// The user's notes steer the combined summary, so they keep up to a quarter of the context.
    let combineInput: SummaryInput

    init(chat: MeetingChat, input: SummaryInput, contextSize: Int, timeout: TimeInterval) {
        self.chat = chat
        self.input = input
        self.contextSize = contextSize
        self.timeout = timeout
        answerTokens = min(2048, contextSize / 4)
        partTokens = min(512, contextSize / 8)
        var combineInput = input
        combineInput.notes = input.notes.trimmed.jsSlice(0, notesBudget(contextSize))
        self.combineInput = combineInput
    }

    func run() async throws -> String {
        let whole = summaryMessages(input)
        if fits(whole, answerTokens) {
            do {
                return try await complete(whole, answerTokens)
            } catch {
                if !isTooLong(error) { throw error }
            }
        }
        var parts: [String] = []
        for section in sections(input.transcript, max: budgetChars(sectionMessages(userName: input.userName, dictionary: input.dictionary, section: ""))) {
            parts += try await summarizeSection(section)
        }
        return try await combine(parts)
    }

    private func summarizeSection(_ section: String) async throws -> [String] {
        do {
            return [try await complete(sectionMessages(userName: input.userName, dictionary: input.dictionary, section: section), partTokens)]
        } catch {
            if !isTooLong(error) || section.utf16Length < minSectionChars * 2 { throw error }
            let (first, second) = halve(section)
            return try await summarizeSection(first) + summarizeSection(second)
        }
    }

    private func combine(_ parts: [String]) async throws -> String {
        var current = parts
        while true {
            let messages = summaryMessages(combineInput, parts: current)
            if current.count > 1 && !fits(messages, answerTokens) {
                current = try await merge(current)
                continue
            }
            do {
                return try await complete(messages, answerTokens)
            } catch {
                if !isTooLong(error) || current.count == 1 { throw error }
                current = try await merge(current)
            }
        }
    }

    /// Merges consecutive parts in groups of at least two, so each round leaves fewer.
    private func merge(_ parts: [String]) async throws -> [String] {
        let max = budgetChars(mergeMessages(dictionary: input.dictionary, parts: []))
        var groups: [[String]] = []
        var group: [String] = []
        var size = 0
        for part in parts {
            if group.count >= 2 && size + part.utf16Length > max {
                groups.append(group)
                group = []
                size = 0
            }
            group.append(part)
            size += part.utf16Length
        }
        if group.count == 1 && !groups.isEmpty {
            groups[groups.count - 1] += group
        } else {
            groups.append(group)
        }
        var merged: [String] = []
        for g in groups { merged.append(try await complete(mergeMessages(dictionary: input.dictionary, parts: g), partTokens)) }
        return merged
    }

    /// Characters of transcript or notes that fit next to `overhead` and a part's answer.
    private func budgetChars(_ overhead: [ChatMessage]) -> Int {
        Swift.max(minSectionChars, (contextSize - estimateTokens(overhead) - partTokens) * charsPerToken)
    }

    private func fits(_ messages: [ChatMessage], _ answerTokens: Int) -> Bool {
        estimateTokens(messages) + answerTokens <= contextSize
    }

    private func complete(_ messages: [ChatMessage], _ maxTokens: Int) async throws -> String {
        try await chat.complete(messages, label: "Summary", timeout: timeout, maxTokens: maxTokens)
    }
}
