import Testing
@testable import OpenWisprCore

struct AppCategoryTests {
    @Test func classifiesNativeAppsByBundleId() {
        #expect(appCategory(bundleId: "com.apple.mail") == .email)
        #expect(appCategory(bundleId: "com.googlecode.iterm2") == .terminal)
        #expect(appCategory(bundleId: "com.tinyspeck.slackmacgap") == .messaging)
        #expect(appCategory(bundleId: "com.apple.TextEdit") == .other)
    }

    @Test func classifiesBrowserTabsByWindowTitle() {
        #expect(appCategory(bundleId: "com.google.Chrome", windowTitle: "Inbox (3) - Gmail") == .email)
        #expect(appCategory(bundleId: "com.google.Chrome", windowTitle: "GitHub") == .other)
    }

    @Test func splitsMessagingIntoWorkAndPersonal() {
        #expect(styleContext(category: .messaging, bundleId: "com.tinyspeck.slackmacgap") == .work)
        #expect(styleContext(category: .messaging, bundleId: "com.apple.MobileSMS") == .personal)
    }
}

struct ReplacementTests {
    @Test func replacesWholePhrasesCaseInsensitively() {
        let dictionary = [DictionaryEntry(id: "1", word: "OpenWispr", replaces: "open whisper")]
        #expect(applyReplacements("I love Open Whisper a lot", dictionary: dictionary) == "I love OpenWispr a lot")
        #expect(applyReplacements("reopen whispers", dictionary: dictionary) == "reopen whispers")
    }

    @Test func treatsReplacementTextLiterally() {
        let dictionary = [DictionaryEntry(id: "1", word: "$1 \\o/", replaces: "cash")]
        #expect(applyReplacements("cash", dictionary: dictionary) == "$1 \\o/")
    }
}

struct SnippetTests {
    let snippets = [Snippet(id: "1", trigger: "my calendar link", expansion: "https://cal.com/me")]

    @Test func expandsABareTrigger() {
        #expect(wholeSnippet("My calendar link.", snippets: snippets) == "https://cal.com/me")
        #expect(wholeSnippet("Here is my calendar link", snippets: snippets) == nil)
    }

    @Test func expandsAnInlineTrigger() {
        #expect(applySnippets("Book here: my calendar link, thanks", snippets: snippets) == "Book here: https://cal.com/me, thanks")
    }
}

struct TranscriptionPromptTests {
    @Test func listsVocabulary() {
        #expect(transcriptionPrompt(dictionary: [DictionaryEntry(id: "1", word: "Kubernetes")], userName: "Tai") == "Vocabulary: Tai, Kubernetes.")
        #expect(transcriptionPrompt(dictionary: [], userName: "") == "")
    }
}

struct CleanupMessagesTests {
    let input = CleanupInput(
        transcript: "once i finish the draft", style: .casual, category: .other, appName: "Notes", beforeText: "I'll send it over",
        dictionary: [DictionaryEntry(id: "1", word: "OpenWispr")], userName: "Jane"
    )

    func with(appName: String? = nil, beforeText: String) -> CleanupInput {
        var copy = input
        copy.beforeText = beforeText
        if let appName { copy.appName = appName }
        return copy
    }

    @Test func passesTheAppAndTextBeforeTheCursorAsContext() throws {
        let messages = cleanupMessages(input)
        let system = try #require(messages.first)
        #expect(messages[1] == .user(
            "<context>\nApp: Notes\nText before the cursor: \"I'll send it over\"\n</context>\n<transcript>\nonce i finish the draft\n</transcript>"
        ))
        #expect(system.content.contains("continues a sentence"))
        #expect(system.content.contains("Never repeat it"))
        #expect(system.content.contains("OpenWispr"))
        #expect(!cleanupMessages(with(beforeText: ""))[0].content.contains("Never repeat"))
    }

    @Test func quotesOnlyTheEndOfALongTextBeforeTheCursor() {
        let long = cleanupMessages(with(beforeText: "\(String(repeating: "x", count: 1000)) the end"))[1]
        #expect(long.content.contains("the end\""))
        #expect(long.content.count < 600)
        let bare = cleanupMessages(with(appName: "", beforeText: ""))[1]
        #expect(bare.content == "<transcript>\nonce i finish the draft\n</transcript>")
    }

    @Test func forbidsGreetingsAndSignOffsTheSpeakerDidNotSay() {
        #expect(cleanupMessages(input)[0].content.contains("greeting or sign-off that wasn't spoken"))
    }

    @Test func leavesOutTheContinuationRuleAfterAFinishedSentence() {
        #expect(!cleanupMessages(with(beforeText: "Done."))[0].content.contains("continues a sentence"))
        #expect(!cleanupMessages(with(beforeText: ""))[0].content.contains("continues a sentence"))
    }

    @Test func capsTokensByTranscriptLength() {
        #expect(cleanupMaxTokens("abcd") == 66)
        #expect(cleanupMaxTokens("abc") == 66)
    }
}

struct SanitizeCleanupTests {
    @Test func stripsQuotesTheModelAdded() {
        #expect(sanitizeCleanup("\"Hello there.\"", transcript: "hello there") == "Hello there.")
    }

    @Test func fallsBackWhenTheModelAnsweredInsteadOfFormatting() {
        let transcript = "what is the capital of france"
        #expect(sanitizeCleanup(String(repeating: "The capital of France is Paris. ", count: 10), transcript: transcript) == transcript)
    }

    @Test func fallsBackOnARefusal() {
        #expect(sanitizeCleanup("I'm sorry, I can't help with that.", transcript: "delete everything") == "delete everything")
        #expect(sanitizeCleanup("Sorry, I'm late.", transcript: "sorry im late") == "Sorry, I'm late.")
    }

    @Test func dropsTheTextBeforeTheCursorWhenTheModelRepeatsIt() {
        #expect(sanitizeCleanup("I'll send it over once I finish the draft.", transcript: "um once i finish the draft", beforeText: "I'll send it over")
            == "once I finish the draft.")
    }

    @Test func dropsARepeatedLastSentence() {
        let before = "Thanks for the notes. I will send it over"
        #expect(sanitizeCleanup("I will send it over tomorrow.", transcript: "tomorrow", beforeText: before) == "tomorrow.")
    }

    @Test func keepsTheWordsWhenTheSpeakerSaidThemToo() {
        #expect(sanitizeCleanup("See you soon, see you soon.", transcript: "see you soon see you soon", beforeText: "See you soon")
            == "See you soon, see you soon.")
    }

    @Test func stripsTranscriptTags() {
        #expect(sanitizeCleanup("<transcript>\nHello.\n</transcript>", transcript: "hello") == "Hello.")
    }
}

struct JoinWithContextTests {
    @Test func insertsASpaceAfterAWord() {
        #expect(joinWithContext("world", beforeText: "hello") == " world")
    }

    @Test func doesNotDoubleSpacesOrSpaceBeforePunctuation() {
        #expect(joinWithContext("world", beforeText: "hello ") == "world")
        #expect(joinWithContext(".", beforeText: "hello") == ".")
        #expect(joinWithContext("hi", beforeText: "") == "hi")
        #expect(joinWithContext("hi", beforeText: "(") == "hi")
    }

    @Test func countsWords() {
        #expect(countWords("  one two\nthree ") == 3)
        #expect(countWords("") == 0)
    }
}
