import Foundation
import Testing
@testable import OpenWisprCore

struct FormatTranscriptTests {
    @Test func mergesConsecutiveEntriesFromTheSameSpeakerIntoOneTurn() {
        let text = formatTranscript(
            [entry(.mic, 0, "Hi all.", length: 1000), entry(.mic, 4000, "Shall we start?", length: 1000), entry(.system, 9000, "Sure.", length: 1000)],
            names: [:], userName: ""
        )
        #expect(text == "[0:00] Me: Hi all. Shall we start?\n[0:09] Others: Sure.")
    }

    @Test func labelsTheUsersTurnsWithTheirNameWhenSet() {
        #expect(formatTranscript([entry(.mic, 65_000, "Hello", length: 1000)], names: [:], userName: "Ada Lovelace") == "[1:05] Ada Lovelace (me): Hello")
    }

    @Test func splitsCallAudioBySpeakerAndAppliesTheNamesTheUserGave() {
        let text = formatTranscript([
            entry(.system, 0, "Morning.", speaker: "app:Alice Smith", length: 1000),
            entry(.system, 2000, "Hi.", speaker: "voice:2", length: 1000),
            entry(.system, 4000, "Let us begin.", speaker: "voice:2", length: 1000),
        ], names: ["voice:2": "Dana"], userName: "")
        #expect(text == "[0:00] Alice Smith: Morning.\n[0:02] Dana: Hi. Let us begin.")
    }
}

struct MeetingTextTests {
    @Test func relabelSummaryRenamesWholeLabelsOnly() {
        let summary = "- [ ] **Speaker 1**: send the deck\n- Speaker 10 agreed. Others joined late."
        #expect(relabelSummary(summary, renames: [SpeakerRename(from: "Speaker 1", to: "Dana"), SpeakerRename(from: "Others", to: "Sam")])
            == "- [ ] **Dana**: send the deck\n- Speaker 10 agreed. Sam joined late.")
    }

    @Test func formatClockFormatsMinutesAndHours() {
        #expect(formatClock(0) == "0:00")
        #expect(formatClock(61_500) == "1:01")
        #expect(formatClock(3_725_000) == "1:02:05")
    }

    @Test func isLikelyHallucinationDropsSubtitleArtifactsButKeepsRealReplies() {
        #expect(isLikelyHallucination("Thanks for watching!"))
        #expect(isLikelyHallucination(" you "))
        #expect(isLikelyHallucination("..."))
        #expect(!isLikelyHallucination("Thank you."))
        #expect(!isLikelyHallucination("Thanks for watching the demo, everyone."))
    }

    @Test func chunkPromptCombinesVocabularyWithTheTailOfThePreviousText() {
        #expect(chunkPrompt(vocabularyPrompt: "Vocabulary: Kubernetes.", previousText: String(repeating: "x", count: 500) + " end")
            .matches(#"^Vocabulary: Kubernetes\. x+ end$"#))
        #expect(chunkPrompt(vocabularyPrompt: "", previousText: "") == "")
    }

    @Test func sanitizeTitleStripsQuotesPrefixesAndTrailingPunctuation() {
        #expect(sanitizeTitle("\"Q3 Roadmap Review.\"") == "Q3 Roadmap Review")
        #expect(sanitizeTitle("Title: Hiring Sync\nBecause they discussed hiring") == "Hiring Sync")
        #expect(sanitizeTitle("**Launch Planning**") == "Launch Planning")
        #expect(sanitizeTitle(String(repeating: "word ", count: 30)).count == 80)
    }

    @Test func sanitizeSummaryUnwrapsAFencedMarkdownAnswer() {
        #expect(sanitizeSummary("```markdown\n### Summary\nShipped.\n```") == "### Summary\nShipped.")
        #expect(sanitizeSummary("### Summary\nShipped.") == "### Summary\nShipped.")
    }

    @Test func summaryMessagesPassNotesAndTranscriptSeparately() throws {
        let messages = summaryMessages(SummaryInput(
            title: "Sync", transcript: "[0:00] Me: Hi", notes: "ask about budget", userName: "",
            dictionary: [DictionaryEntry(id: "1", word: "Wispr")], recordedAt: 1_767_625_200_000
        ))
        let system = try #require(messages.first)
        #expect(system.content.contains("\"Me\" is the user"))
        #expect(system.content.contains("### Action Items"))
        #expect(system.content.contains("Wispr"))
        #expect(messages[1].content.contains("<notes>\nask about budget\n</notes>"))
        #expect(messages[1].content.contains("<transcript>\n[0:00] Me: Hi\n</transcript>"))
        #expect(messages[1].content.contains("Date: Monday, January 5, 2026"))
    }
}

struct SummaryStateTests {
    let meeting: Meeting = {
        var meeting = Meeting(id: "m", createdAt: 0)
        meeting.recordedMs = 60_000
        meeting.transcriptWords = minSummaryWords
        return meeting
    }()

    func with(_ change: (inout Meeting) -> Void) -> Meeting {
        var copy = meeting
        change(&copy)
        return copy
    }

    @Test func waitsForTheMeetingToEndBeforeOfferingASummary() {
        #expect(summaryState(meeting, recording: true) == .notYetGeneratable)
        #expect(summaryState(meeting, recording: false) == .readyToGenerate)
    }

    @Test func reportsShortAndEmptyMeetings() {
        #expect(summaryState(with { $0.transcriptWords = 3 }, recording: false) == .tooShort(noAudio: false))
        #expect(summaryState(with { $0.recordedMs = 0; $0.transcriptWords = 0 }, recording: false) == .tooShort(noAudio: true))
    }

    @Test func offersAnUpdateWhenAudioWasRecordedAfterTheSummary() {
        let summarized = with { $0.summary = "S"; $0.summaryRecordedMs = 60_000 }
        #expect(summaryState(summarized, recording: false) == .generated(summary: "S"))
        var longer = summarized
        longer.recordedMs = 90_000
        #expect(summaryState(longer, recording: false) == .updateAvailable(summary: "S"))
        #expect(summaryState(longer, recording: true) == .generated(summary: "S"))
        var generating = summarized
        generating.summaryGenerating = true
        #expect(summaryState(generating, recording: false) == .updating(summary: "S"))
    }

    @Test func keepsThePreviousSummaryVisibleWhenRegenerationFails() {
        #expect(summaryState(with { $0.summary = "S"; $0.summaryError = "boom" }, recording: false) == .failed(summary: "S", error: "boom"))
    }
}

private func status(
    _ id: String, task: ModelTask = .chat, engine: ModelEngine = .mlx, state: DownloadState = .notDownloaded, oversized: Bool = false, recommended: Bool = true
) -> ModelStatus {
    ModelStatus(
        model: ModelEntry(id: id, name: id, task: task, engine: engine, sources: [], sizeBytes: 1, memoryBytes: 1, speed: .fast, languages: "", languageCodes: nil),
        recommended: recommended, userAdded: !recommended, oversized: oversized, state: state, preparing: false
    )
}

struct OfferedModelTests {
    let installed = DownloadState.installed(sizeBytes: 1)

    @Test func offersTheFirstRecommendedChatModelThisMacHasTheMemoryFor() {
        let models = [status("whisper", task: .speechToText, engine: .whisperKit), status("huge", oversized: true), status("small"), status("medium")]
        #expect(offeredModel(models, role: .chat)?.model.id == "small")
    }

    @Test func prefersAChatModelThatIsAlreadyInstalled() {
        #expect(offeredModel([status("small"), status("mine", state: installed, recommended: false)], role: .chat)?.model.id == "mine")
    }

    @Test func skipsModelsThatCantRunAndOffersNothingWhenNoneFit() {
        let models = [status("vision", task: .vision, state: installed), status("huge", oversized: true), status("mine", recommended: false)]
        #expect(offeredModel(models, role: .chat) == nil)
    }

    @Test func narrowsTheOfferToAnEngine() {
        let models = [status("parakeet", task: .speechToText, engine: .fluidAudio, state: installed), status("whisper", task: .speechToText, engine: .whisperKit)]
        #expect(offeredModel(models, role: .speechToText, engine: .whisperKit)?.model.id == "whisper")
    }
}
