import Foundation
import Synchronization
import Testing
@testable import OpenWisprCore

/// Built-in chat whose model has `contextSize` tokens and counts `charsPerToken` characters as one token.
/// Like Apple's, it rejects a request that leaves fewer than 16 tokens for the answer, and answers the nth
/// completion with `answer(n)`. With `chatModel`, that downloaded model has `contextSize` and Apple's chat
/// model a smaller one.
private final class ChatModel: Sendable {
    let engines: FakeEngines
    private final class Sent: Sendable {
        let requests = Mutex<[[ChatMessage]]>([])
    }

    private let sent = Sent()

    init(contextSize: Int, charsPerToken: Int = 4, chatModel: String? = nil, answer: @escaping @Sendable (Int) -> String = { "S\($0)" }) {
        var script = FakeEngines.Script()
        script.status = BuiltInStatus(
            appleSpeech: .init(available: true, locale: "en-US", locales: ["en-US"]),
            appleChat: .init(available: true, contextSize: chatModel == nil ? contextSize : 4096),
            chat: chatModel.map { .init(model: $0, name: $0, contextSize: contextSize) }
        )
        engines = FakeEngines(script)
        let sent = sent
        engines.update {
            $0.completeHandler = { messages, _ in
                let count = sent.requests.withLock {
                    $0.append(messages)
                    return $0.count
                }
                let chars = messages.reduce(0) { $0 + $1.content.utf16.count }
                let used = (chars + charsPerToken - 1) / charsPerToken
                if contextSize - used < 16 { throw ModelError.contextExceeded("Too long (\(used) of \(contextSize) tokens)") }
                return answer(count)
            }
        }
    }

    var completions: [String] { sent.requests.withLock { $0 }.map { $0.map(\.content).joined(separator: "\n") } }
}

/// One line per speaker turn, as `formatTranscript` writes them; each turn is about 50 tokens.
private func transcript(_ turns: Int) -> String {
    (0..<turns).map { i in
        "[\(i / 2):\(i % 2 == 1 ? "30" : "00")] \(i % 2 == 1 ? "Dana" : "Me"): Turn \(i) talks about the budget, the launch date and who sends the deck."
    }.joined(separator: "\n")
}

private func meeting(_ lines: String, notes: String = "ask about budget") -> SummaryInput {
    SummaryInput(title: "Planning", transcript: lines, notes: notes, userName: "", dictionary: [], recordedAt: 1_767_625_200_000)
}

/// The transcript lines each request carries, in order.
private func covered(_ requests: [String], _ lines: String) -> [String] {
    let transcriptLines = Set(lines.components(separatedBy: "\n"))
    return requests.flatMap { $0.components(separatedBy: "\n").filter(transcriptLines.contains) }
}

@MainActor
private func appleModels(_ chat: ChatModel) async throws -> Models {
    var settings = Settings()
    settings.language = "en"
    return await makeModels(engines: chat.engines, settings: SettingsBox(settings), directory: try temporaryDirectory())
}

@MainActor
@Suite("summarizeMeeting")
struct SummarizeMeetingTests {
    @Test func `summarizes a meeting longer than the chat model's context in pieces, then combines them with the user's notes`() async throws {
        let chat = ChatModel(contextSize: 4096)
        let lines = transcript(400)

        let summary = try await summarizeMeeting(try await appleModels(chat), meeting(lines))

        let completions = chat.completions
        #expect(completions.count > 2)
        let final = try #require(completions.last)
        #expect(summary == "S\(completions.count)")
        #expect(covered(Array(completions.dropLast()), lines) == lines.components(separatedBy: "\n"))
        for n in 1..<completions.count { #expect(final.contains("S\(n)")) }
        #expect(final.contains("ask about budget"))
        #expect(!final.contains("Turn 0 "))
    }

    @Test func `sends a meeting that fits the context in one request, however large the context is`() async throws {
        let lines = transcript(400)
        let large = ChatModel(contextSize: 32_768)
        #expect(try await summarizeMeeting(try await appleModels(large), meeting(lines)) == "S1")
        #expect(large.completions.count == 1)
        #expect(large.completions[0].contains(lines))
        #expect(large.completions[0].contains("ask about budget"))

        let small = ChatModel(contextSize: 4096)
        _ = try await summarizeMeeting(try await appleModels(small), meeting(transcript(10)))
        #expect(small.completions.count == 1)
    }

    @Test func `sizes the pieces from a downloaded MLX chat model's context`() async throws {
        let directory = try temporaryDirectory()
        let id = "qwen3-4b-instruct-2507"
        let entry = try #require(recommendedModels.first { $0.id == id })
        try FileManager.default.createDirectory(at: directory.appending(path: id), withIntermediateDirectories: true)
        writeJsonAtomic(directory.appending(path: "\(id)/manifest.json"), ModelManifest(entry: entry, userAdded: false, installed: true, files: []))
        let chat = ChatModel(contextSize: 32_768, chatModel: id)
        var settings = Settings()
        settings.chat = .builtIn(modelId: id)
        let models = await makeModels(engines: chat.engines, settings: SettingsBox(settings), directory: directory)
        let lines = transcript(1600)

        let summary = try await summarizeMeeting(models, meeting(lines))

        let completions = chat.completions
        #expect(summary == "S\(completions.count)")
        #expect(chat.engines.calls.allSatisfy { if case let .complete(model, _) = $0 { model == id } else { true } })
        let sections = Array(completions.dropLast())
        #expect(sections.count > 1)
        #expect(sections.count < 8)
        for section in sections { #expect(section.utf16.count / 4 > 4096) }
        #expect(covered(sections, lines) == lines.components(separatedBy: "\n"))
    }

    @Test func `splits a section further when the model counts more tokens than expected`() async throws {
        let chat = ChatModel(contextSize: 4096, charsPerToken: 2)
        let lines = transcript(400)

        let summary = try await summarizeMeeting(try await appleModels(chat), meeting(lines))

        #expect(summary == "S\(chat.completions.count)")
        #expect(Set(covered(Array(chat.completions.dropLast()), lines)) == Set(lines.components(separatedBy: "\n")))
    }

    @Test func `merges partial summaries that are too long to combine at once, keeping the notes for the end`() async throws {
        let long: @Sendable (Int) -> String = { n in "S\(n) \(String(repeating: "decided something. ", count: 80))" }
        let chat = ChatModel(contextSize: 4096, answer: long)

        let summary = try await summarizeMeeting(try await appleModels(chat), meeting(transcript(800)))

        #expect(summary == long(chat.completions.count).trimmed)
        #expect(chat.completions.last?.contains("ask about budget") == true)
        #expect(!chat.completions.dropLast().contains { $0.contains("ask about budget") })
    }

    @Test func `sends Endpoints the whole meeting in one request`() async throws {
        let http = FakeHub { _, _ in .json(#"{"choices":[{"message":{"content":"```markdown\n### Summary\nShipped.\n```"}}]}"#) }
        var settings = Settings()
        settings.chat = .endpoint(EndpointConfig(baseUrl: "https://chat.example/v1", model: "gpt-x", apiKey: "k"))
        let endpoint = await makeModels(http, settings: SettingsBox(settings), directory: try temporaryDirectory())
        let lines = transcript(400)

        #expect(try await summarizeMeeting(endpoint, meeting(lines)) == "### Summary\nShipped.")
        #expect(http.requests.count == 1)
        let messages = try #require(http.requests.first?.json?["messages"] as? [[String: String]])
        #expect(messages.compactMap { $0["content"] }.joined(separator: "\n").contains(lines))
    }
}

@MainActor
@Suite("titleMeeting")
struct TitleMeetingTests {
    @Test func `names a long meeting from as much of its beginning as fits the chat model's context`() async throws {
        let chat = ChatModel(contextSize: 4096) { _ in "\"Launch Planning.\"" }
        let lines = transcript(400)

        #expect(try await titleMeeting(try await appleModels(chat), transcript: lines, notes: "ask about budget") == "Launch Planning")

        #expect(chat.completions.count == 1)
        #expect(chat.completions[0].contains(lines.components(separatedBy: "\n").prefix(20).joined(separator: "\n")))
        #expect(chat.completions[0].contains("ask about budget"))
    }
}
