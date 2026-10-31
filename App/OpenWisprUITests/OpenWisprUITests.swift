import XCTest

/// Drives the app with `--ui-testing`: fake microphone, models and meeting audio, data in a temporary folder.
@MainActor
final class OpenWisprUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
    }

    override func tearDown() async throws {
        app.terminate()
    }

    private var window: XCUIElement { app.windows["OpenWispr"].firstMatch }

    private func open(_ page: String) {
        let item = app.descendants(matching: .any)["nav-\(page.lowercased())"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }

    /// Opens the Settings window from the hub's sidebar unless it's already open, then selects `pane` in its own sidebar.
    private func openSettings(_ pane: String) {
        let item = app.descendants(matching: .any)["settings-\(pane)"].firstMatch
        if !item.exists { open("Settings") }
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }

    /// Settings panes are lazy Forms: rows below the fold join the accessibility tree only once scrolled into view.
    private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let pane = app.descendants(matching: .any)["settings-pane"].firstMatch
        for _ in 0..<15 where !element.exists {
            pane.scroll(byDeltaX: 0, deltaY: -200)
        }
        XCTAssertTrue(element.exists, file: file, line: line)
    }

    func testHomeShowsStatsAndEmptyHistory() {
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["words dictated"].exists)
        XCTAssertTrue(app.staticTexts["Your dictations will show up here."].exists)
        XCTAssertFalse(app.otherElements["setup-card"].exists, "Permissions are faked as granted under UI testing")
    }

    func testHandsFreeDictationFromTheFlowBarLandsInHistory() {
        let start = app.buttons["flow-bar-start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()

        let stop = app.buttons["flow-bar-stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["flow-bar-cancel"].exists)
        stop.click()

        let entry = app.staticTexts["Hello from the UI test."].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["TextEdit · hands-free"].exists)
        XCTAssertTrue(start.waitForExistence(timeout: 10), "The bar rests again after pasting")
    }

    func testCancelledDictationLeavesNoHistory() {
        let start = app.buttons["flow-bar-start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        let cancel = app.buttons["flow-bar-cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Hello from the UI test."].exists)
    }

    func testDictionaryAddAndDelete() {
        open("Dictionary")
        let word = app.textFields["dictionary-word"].firstMatch
        XCTAssertTrue(word.waitForExistence(timeout: 5))
        word.click()
        word.typeText("Kubernetes")
        let replaces = app.textFields["dictionary-replaces"].firstMatch
        replaces.click()
        replaces.typeText("cooper netties")
        app.buttons["dictionary-add"].click()

        XCTAssertTrue(app.staticTexts["Kubernetes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["← cooper netties"].exists)
        app.descendants(matching: .any)["dictionary-delete"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No words yet."].waitForExistence(timeout: 5))
    }

    func testSnippetsAdd() {
        open("Snippets")
        let trigger = app.textFields["snippet-trigger"].firstMatch
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.click()
        trigger.typeText("my calendar link")
        let expansion = app.textFields["snippet-expansion"].firstMatch
        expansion.click()
        expansion.typeText("https://cal.com/openwispr")
        app.buttons["snippet-add"].click()
        XCTAssertTrue(app.staticTexts["“my calendar link”"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["https://cal.com/openwispr"].exists)
    }

    func testStyleSelection() {
        open("Style")
        let excited = app.buttons["style-email-excited"].firstMatch
        XCTAssertTrue(excited.waitForExistence(timeout: 5))
        XCTAssertFalse(excited.isSelected)
        excited.click()
        XCTAssertTrue(excited.isSelected)
        XCTAssertTrue(app.buttons["style-email-formal"].exists)
        XCTAssertFalse(app.buttons["style-email-formal"].isSelected)
    }

    func testSettingsRowOpensTheSettingsWindowOnItsLastPane() {
        openSettings("permissions")
        XCTAssertTrue(app.staticTexts["Accessibility"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.exists, "The hub stays open behind the Settings window")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.staticTexts["Accessibility"].waitForExistence(timeout: 2))

        open("Settings")
        XCTAssertTrue(app.staticTexts["Accessibility"].waitForExistence(timeout: 5))
    }

    func testSettingsShowsBuiltInModelsAndAppleStatus() {
        openSettings("speechToText")
        XCTAssertTrue(app.staticTexts["Transcribes as en-US. The first dictation in a new language downloads Apple’s language files."].waitForExistence(timeout: 10))
        openSettings("languageModels")
        XCTAssertTrue(app.staticTexts["Reads up to 4096 tokens per request on this Mac."].waitForExistence(timeout: 10))
        openSettings("modelLibrary")
        XCTAssertTrue(app.staticTexts["Built-in models"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["Add from Hugging Face"])
        openSettings("shortcuts")
        XCTAssertTrue(app.staticTexts["Push to talk (hold)"].waitForExistence(timeout: 5))
    }

    func testModelPickersOfferCloudProvidersAndCustomServers() {
        openSettings("languageModels")
        let chat = app.popUpButtons["picker-chat"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        func choose(_ item: String) {
            chat.click()
            let menuItem = chat.menuItems[item].firstMatch
            XCTAssertTrue(menuItem.waitForExistence(timeout: 5), item)
            menuItem.click()
        }

        chat.click()
        for item in ["OpenAI", "Ollama (local)", "LM Studio (local)", "Amazon Bedrock", "Google Cloud Agent Platform", "Custom OpenAI-compatible server"] {
            XCTAssertTrue(chat.menuItems[item].exists, item)
        }
        XCTAssertFalse(chat.menuItems["Groq"].exists)
        app.typeKey(.escape, modifierFlags: [])

        choose("Amazon Bedrock")
        XCTAssertTrue(app.staticTexts["Credentials"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["Test connection"])

        choose("Google Cloud Agent Platform")
        XCTAssertTrue(app.staticTexts["Project"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Location"].exists)

        choose("Custom OpenAI-compatible server")
        XCTAssertTrue(app.staticTexts["Base URL"].waitForExistence(timeout: 5))
        XCTAssertEqual(chat.value as? String, "Custom OpenAI-compatible server")
        app.buttons["Test"].firstMatch.click()
        let unset = app.staticTexts["Enter the server's base URL, like http://localhost:8080/v1"].firstMatch
        XCTAssertTrue(unset.waitForExistence(timeout: 10))
        choose("Amazon Bedrock")
        XCTAssertTrue(app.staticTexts["Credentials"].waitForExistence(timeout: 5))
        XCTAssertFalse(unset.exists, "A test result doesn't outlive the selection it tested")

        openSettings("speechToText")
        let speech = app.popUpButtons["picker-speechToText"].firstMatch
        XCTAssertTrue(speech.waitForExistence(timeout: 5))
        speech.click()
        XCTAssertTrue(speech.menuItems["Speaches / faster-whisper (local)"].waitForExistence(timeout: 5))
        XCTAssertFalse(speech.menuItems["Amazon Bedrock"].exists)
        XCTAssertFalse(speech.menuItems["Ollama (local)"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testAppearanceSwitchesToDarkAndBack() {
        openSettings("general")
        let picker = app.radioGroups["picker-appearance"].firstMatch
        reveal(picker)
        // A segmented picker marks its chosen segment with a value of 1.
        func chosen(_ label: String) -> Bool { picker.radioButtons[label].value as? Int == 1 }
        let applied = app.staticTexts["applied-color-scheme"].firstMatch
        func scheme() -> String { applied.value as? String ?? applied.label }
        XCTAssertTrue(chosen("System"))
        let systemScheme = scheme()

        picker.radioButtons["Dark"].click()
        XCTAssertTrue(chosen("Dark"))
        XCTAssertEqual(scheme(), "dark")

        picker.radioButtons["Light"].click()
        XCTAssertTrue(chosen("Light"))
        XCTAssertEqual(scheme(), "light")
        let flowBar = app.staticTexts["flow-bar-color-scheme"].firstMatch
        XCTAssertEqual(flowBar.value as? String ?? flowBar.label, "dark", "The Flow bar stays dark in light mode")

        picker.radioButtons["System"].click()
        XCTAssertTrue(chosen("System"))
        XCTAssertEqual(scheme(), systemScheme)
    }

    func testMeetingIsTranscribedAttributedAndSummarized() {
        open("Notetaker")
        let newNote = app.buttons["new-note"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 5))
        newNote.click()

        let stop = app.buttons["meeting-stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Google Meet: Alice Smith talking"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Let's ship the beta on Friday once the last onboarding bugs are fixed and QA signs off."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sounds good, I will update the docs by Thursday and send the release notes to everyone."].waitForExistence(timeout: 10))
        stop.click()

        XCTAssertTrue(app.staticTexts["The team agreed to ship the beta on Friday."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Alice Smith"].firstMatch.exists)
        let title = app.textFields["meeting-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Beta launch planning")

        app.descendants(matching: .any)["meeting-back"].firstMatch.click()
        XCTAssertTrue(app.buttons["Beta launch planning"].waitForExistence(timeout: 5))
    }
}
