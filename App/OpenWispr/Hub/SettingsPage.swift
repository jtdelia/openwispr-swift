import OpenWisprCore
import SwiftUI

/// An Endpoint offered by name, with the models it's set up with for each role.
private struct KnownEndpoint: Hashable {
    let label: String
    let baseUrl: String
    let speechToTextModel: String
    let chatModel: String

    static let all = [
        KnownEndpoint(label: "OpenAI", baseUrl: "https://api.openai.com/v1", speechToTextModel: "gpt-4o-mini-transcribe", chatModel: "gpt-4.1-mini"),
        KnownEndpoint(label: "Groq", baseUrl: "https://api.groq.com/openai/v1", speechToTextModel: "whisper-large-v3-turbo", chatModel: "llama-3.3-70b-versatile"),
        KnownEndpoint(
            label: "Local (Speaches / faster-whisper)", baseUrl: "http://localhost:8000/v1",
            speechToTextModel: "Systran/faster-distil-whisper-large-v3", chatModel: ""
        ),
    ]

    static func offered(for role: ModelRole) -> [KnownEndpoint] {
        role == .chat ? all.filter { !$0.chatModel.isEmpty } : all
    }

    func model(for role: ModelRole) -> String { role == .chat ? chatModel : speechToTextModel }
}

/// What the model picker shows as selected.
private enum ModelChoice: Hashable {
    case apple
    case downloaded(String)
    case endpoint(String)
    case custom
}

/// The Apple Intelligence & Siri pane; there's no deep link to the switch itself.
private let appleIntelligenceSettings = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!

struct SettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.store.settings
        Form {
            Section("Permissions") {
                LabeledContent {
                    if model.permissions.accessibility {
                        Badge(text: "Granted", tone: .ok)
                    } else {
                        Button("Grant access") { model.requestAccessibility() }
                    }
                } label: {
                    Text("Accessibility")
                    Text("Detects your dictation shortcut and pastes text into the focused app.")
                }
                LabeledContent {
                    if model.permissions.microphone {
                        Badge(text: "Granted", tone: .ok)
                    } else {
                        Button("Allow") { Task { _ = await model.requestMicrophone() } }
                    }
                } label: {
                    Text("Microphone")
                    Text("Records audio while you dictate.")
                }
                if model.permissions.accessibility && !model.permissions.keyTapRunning {
                    ErrorText("OpenWispr can't listen for shortcuts yet. Quit and reopen it after granting Accessibility.")
                }
            }

            SpeechToTextSection()
            ChatSection()
            ModelsSection()

            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    ShortcutRow(action: action)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Tip: if fn opens the emoji picker, set System Settings → Keyboard → “Press 🌐 key to” → “Do Nothing”.")
            }

            Section("Microphone") {
                MicrophonePicker(value: settings.microphoneId)
            }

            Section("General") {
                LabeledContent {
                    CommitTextField(value: settings.userName, placeholder: "Jane Doe") { name in model.updateSettings { $0.userName = name } }
                        .frame(width: 220)
                } label: {
                    Text("Your name")
                    Text("Helps with spelling and sign-offs.")
                }
                Picker("Appearance", selection: Binding(get: { settings.appearance }, set: { value in model.updateSettings { $0.appearance = value } })) {
                    ForEach(Appearance.allCases, id: \.self) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("picker-appearance")
                Toggle("Sound effects", isOn: binding(\.sounds))
                Toggle(isOn: binding(\.showFlowBar)) {
                    Text("Show Flow bar while idle")
                    Text("The small pill at the bottom of the screen. It always appears while dictating.")
                }
                .accessibilityIdentifier("toggle-flow-bar")
                Toggle("Restore clipboard after pasting", isOn: binding(\.restoreClipboard))
                Toggle("Launch at login", isOn: binding(\.launchAtLogin))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private func binding(_ keyPath: WritableKeyPath<OpenWisprCore.Settings, Bool>) -> Binding<Bool> {
        Binding(get: { model.store.settings[keyPath: keyPath] }, set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }
}

// MARK: Model selection

private struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    let role: ModelRole

    var body: some View {
        let selection = model.store.settings[role]
        Picker("Model or Endpoint", selection: Binding(get: { choice(selection) }, set: select)) {
            Text("Apple (on this Mac)").tag(ModelChoice.apple)
            ForEach(options(selection)) { status in
                Text("\(status.model.name) (on this Mac)").tag(ModelChoice.downloaded(status.model.id))
            }
            ForEach(KnownEndpoint.offered(for: role), id: \.self) { endpoint in
                Text(endpoint.label).tag(ModelChoice.endpoint(endpoint.label))
            }
            Text("Custom").tag(ModelChoice.custom).selectionDisabled()
        }
        .accessibilityIdentifier("picker-\(role.rawValue)")
    }

    /// Installed models for `role` OpenWispr can run, plus the selected one even if it isn't installed.
    private func options(_ selection: ModelSelection) -> [ModelStatus] {
        model.models.library.models.filter { status in
            status.model.task == ModelTask(role)
                && ((status.state.isInstalled && status.model.isRunnable) || selection.builtInModelId == status.model.id)
        }
    }

    private func choice(_ selection: ModelSelection) -> ModelChoice {
        switch selection {
        case let .builtIn(id): id == appleModelId ? .apple : .downloaded(id)
        case let .endpoint(config): KnownEndpoint.offered(for: role).first { $0.baseUrl == config.baseUrl }.map { .endpoint($0.label) } ?? .custom
        }
    }

    private func select(_ choice: ModelChoice) {
        switch choice {
        case .apple: model.updateSelection(role, .builtIn(modelId: appleModelId))
        case let .downloaded(id): model.updateSelection(role, .builtIn(modelId: id))
        case let .endpoint(label):
            guard let endpoint = KnownEndpoint.offered(for: role).first(where: { $0.label == label }) else { return }
            model.updateSelection(role, .endpoint(baseUrl: endpoint.baseUrl, model: endpoint.model(for: role)))
        case .custom: return
        }
    }
}

private struct SpeechToTextSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.store.settings
        Section {
            ModelPicker(role: .speechToText)
            SelectionSettings(role: .speechToText)
            LabeledContent {
                CommitTextField(value: settings.language, placeholder: "auto") { language in model.updateSettings { $0.language = language } }
                    .frame(width: 120)
                    .accessibilityIdentifier("language")
            } label: {
                Text("Language")
                Text(settings.speechToText.isApple
                    ? "ISO code like en or de. Leave empty to use your Mac’s language."
                    : "ISO code like en or de. Leave empty to auto-detect.")
            }
            if settings.speechToText.isApple {
                AppleSpeechStatus()
            } else if settings.speechToText.builtInModelId != nil {
                DownloadedSpeechStatus()
            }
        } header: {
            Text("Speech-to-text")
        } footer: {
            Text("Apple’s on-device model, a downloaded Built-in model, or any OpenAI-compatible speech-to-text Endpoint.")
        }
    }
}

private struct ChatSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.store.settings
        Section {
            Toggle(isOn: Binding(get: { settings.cleanup.enabled }, set: { value in model.updateSettings { $0.cleanup.enabled = value } })) {
                Text("Clean up dictations")
                Text("Removes filler words, applies self-corrections, fixes punctuation and matches your style.")
            }
            .accessibilityIdentifier("toggle-cleanup")
            ModelPicker(role: .chat)
            SelectionSettings(
                role: .chat,
                keyDescription: settings.chat.endpoint != nil && settings.chat.endpoint?.baseUrl == settings.speechToText.endpoint?.baseUrl
                    ? "Uses the speech-to-text key when left empty." : nil
            )
            if settings.chat.isApple {
                AppleChatStatus()
            } else if settings.chat.builtInModelId != nil, let chat = model.builtInStatus?.chat {
                Text("Reads up to \(String(chat.contextSize)) tokens per request.").font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Chat")
        } footer: {
            Text("Cleans up dictations and writes meeting titles and summaries.")
        }
    }
}

private struct SelectionSettings: View {
    @Environment(AppModel.self) private var model
    let role: ModelRole
    var keyDescription: String?

    var body: some View {
        switch model.store.settings[role] {
        case let .builtIn(id) where id == appleModelId:
            LabeledContent {
                Badge(text: "Built-in", tone: .ok)
            } label: {
                Text("Model")
                Text(role == .speechToText
                    ? "Apple’s on-device speech-to-text. Your audio never leaves this Mac."
                    : "Apple Intelligence’s on-device model. Your text never leaves this Mac.")
            }
        case let .builtIn(id):
            if let status = model.models.library.models.first(where: { $0.model.id == id }) {
                DownloadedModelRow(role: role, status: status)
            }
        case let .endpoint(config):
            LabeledContent("Base URL") {
                CommitTextField(value: config.baseUrl) { value in model.updateSelection(role, .endpoint(baseUrl: value)) }
            }
            LabeledContent("Model") {
                CommitTextField(value: config.model) { value in model.updateSelection(role, .endpoint(model: value)) }
            }
            LabeledContent {
                SecretField(hasValue: !config.apiKey.isEmpty) { value in model.updateSelection(role, .endpoint(apiKey: value)) }
            } label: {
                Text("API key")
                if let keyDescription { Text(keyDescription) }
            }
            EndpointTest(role: role)
        }
    }
}

/// The selected downloaded model: ready, preparing, or still to be downloaded.
private struct DownloadedModelRow: View {
    @Environment(AppModel.self) private var model
    let role: ModelRole
    let status: ModelStatus

    var body: some View {
        let name = status.model.name
        let isSpeech = role == .speechToText
        LabeledContent {
            switch status.state {
            case .installed:
                if status.model.isRunnable { Badge(text: "Built-in", tone: .ok) } else { useApple }
            case .downloading:
                useApple
            case .notDownloaded, .paused:
                HStack {
                    useApple
                    Button("\(isPaused ? "Resume" : "Download") (\(Format.bytes(status.model.sizeBytes)))") {
                        Task { try? await model.models.download(status.model.id) }
                    }
                }
            }
        } label: {
            Text("Model")
            switch status.state {
            case .installed:
                if !status.model.isRunnable {
                    Text("\(name) needs an engine OpenWispr doesn’t have yet.")
                } else if status.preparing {
                    Text("Preparing \(name) for this Mac… \(isSpeech ? "The first load compiles it and can take a couple of minutes." : "Loading it into memory takes a few seconds.")")
                } else {
                    Text("\(name) runs on this Mac. \(isSpeech ? "Your audio never leaves this Mac." : "Your text never leaves this Mac.")")
                }
            case let .downloading(done, total, _):
                Text("Downloading \(name)… \(Format.percent(done, total))%. \(isSpeech ? "Dictation uses it" : "Cleanup and meeting summaries use it") once it’s installed.")
            case .notDownloaded, .paused:
                Text("\(name) isn’t downloaded yet.")
            }
        }
    }

    private var isPaused: Bool {
        if case .paused = status.state { return true }
        return false
    }

    private var useApple: some View {
        Button("Use Apple") { model.updateSelection(role, .builtIn(modelId: appleModelId)) }.buttonStyle(.link)
    }
}

/// One click to switch `role` to a downloaded model, downloading it first if needed.
private struct ModelOffer: View {
    @Environment(AppModel.self) private var model
    let role: ModelRole
    var engine: ModelEngine?

    var body: some View {
        if let offer = offeredModel(model.models.library.models, role: role, engine: engine) {
            Button(offer.state.isInstalled ? "Use \(offer.model.name)" : "Download \(offer.model.name) (\(Format.bytes(offer.model.sizeBytes)))") {
                if !offer.state.isInstalled { Task { try? await model.models.download(offer.model.id) } }
                model.updateSelection(role, .builtIn(modelId: offer.model.id))
            }
        }
    }
}

private struct AppleSpeechStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let language = model.store.settings.language
        if case let .appleSpeechAssets(locale, fraction)? = model.models.progress {
            Text("Downloading Apple’s speech-to-text for \(locale)… \(Int((fraction * 100).rounded()))%").font(.callout).foregroundStyle(.secondary)
        } else if let error = model.builtInStatusError {
            ErrorText("Couldn’t check Apple’s speech-to-text: \(error)")
        } else if let speech = model.builtInStatus?.appleSpeech {
            if !speech.available {
                ErrorText(speech.reason ?? "Apple’s speech-to-text is unavailable.")
            } else if let locale = speech.locale {
                Text("Transcribes as \(locale). The first dictation in a new language downloads Apple’s language files.")
                    .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("apple-speech-status")
            } else {
                let supported = Array(Set(speech.locales.map { Format.languageName(String($0.split(separator: "-")[0])) })).sorted()
                VStack(alignment: .leading, spacing: 8) {
                    ErrorText("Apple’s speech-to-text doesn’t support \(Format.languageName(language)). On this Mac it supports \(supported.joined(separator: ", ")). Choose one of these, use a Whisper model, or use an Endpoint for this language.")
                    ModelOffer(role: .speechToText, engine: .whisperKit)
                }
            }
        }
    }
}

private struct DownloadedSpeechStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let speech = model.builtInStatus?.speechToText, !speech.supported, let languages = speech.languages {
            VStack(alignment: .leading, spacing: 8) {
                ErrorText("\(speech.name) doesn’t support \(Format.languageName(model.store.settings.language)). It supports \(languages.map(Format.languageName).joined(separator: ", ")). Choose one of these, or use a Whisper model or an Endpoint for this language.")
                ModelOffer(role: .speechToText, engine: .whisperKit)
            }
        }
    }
}

/// Whether Apple Intelligence is on, checked again when the user comes back from System Settings.
private struct AppleChatStatus: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let error = model.builtInStatusError {
                ErrorText("Couldn’t check Apple’s chat model: \(error)")
            } else if let chat = model.builtInStatus?.appleChat {
                if chat.available {
                    Text("Reads up to \(String(chat.contextSize ?? 0)) tokens per request on this Mac.").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ErrorText("\(chat.reason ?? "Apple Intelligence is unavailable"), so dictations are inserted without Cleanup and meetings get no title or summary. \(fixText(chat.fix))You can also use a chat model downloaded to this Mac.")
                        HStack {
                            if chat.fix == .turnOnAppleIntelligence {
                                Button("Open Apple Intelligence & Siri Settings") { openURL(appleIntelligenceSettings) }
                            }
                            ModelOffer(role: .chat)
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshBuiltInStatus() }
        }
    }

    private func fixText(_ fix: BuiltInStatus.AppleChatFix?) -> String {
        switch fix {
        case .turnOnAppleIntelligence: "Turn it on in System Settings → Apple Intelligence & Siri, or use an Endpoint. "
        case .wait: "It’s usable once the download finishes. "
        case nil: ""
        }
    }
}

private struct EndpointTest: View {
    @Environment(AppModel.self) private var model
    let role: ModelRole
    @State private var result: EndpointTestResult?
    @State private var testing = false

    var body: some View {
        LabeledContent {
            HStack {
                if result == .ok { Badge(text: "Working", tone: .ok) }
                Button(testing ? "Testing…" : "Test") {
                    testing = true
                    Task {
                        result = await model.models.testEndpoint(role)
                        testing = false
                    }
                }
                .disabled(testing)
            }
        } label: {
            Text("Test Endpoint")
            Text("Sends a tiny request to check it answers.")
        }
        if case let .failed(error)? = result { ErrorText(error) }
    }
}

// MARK: Shortcuts and devices

private struct ShortcutRow: View {
    @Environment(AppModel.self) private var model
    let action: ShortcutAction

    var body: some View {
        let current = model.store.settings.shortcuts[action]
        let capture = model.capture?.action == action ? model.capture : nil
        LabeledContent(action.label) {
            HStack(spacing: 10) {
                Group {
                    if let capture {
                        Text(capture.combo.isEmpty ? "Press keys…" : Key.comboLabel(Array(capture.combo)))
                    } else {
                        Text(current.isEmpty ? "None" : Key.comboLabel(current))
                    }
                }
                .font(.callout.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(capture == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor.opacity(0.25)), in: .rect(cornerRadius: 6))
                if capture != nil {
                    Button("Cancel") { model.cancelCapture() }.buttonStyle(.link)
                } else {
                    Button("Change") { model.startCapture(action) }.buttonStyle(.link)
                    if Key.comboLabel(current) != Key.comboLabel(Shortcuts.defaults[action]) {
                        Button("Reset") { model.updateSettings { $0.shortcuts[action] = Shortcuts.defaults[action] } }.buttonStyle(.link)
                    }
                }
            }
        }
    }
}

private struct MicrophonePicker: View {
    @Environment(AppModel.self) private var model
    let value: String
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Picker("Input device", selection: Binding(get: { value }, set: { id in model.updateSettings { $0.microphoneId = id } })) {
            Text("System default").tag("")
            ForEach(devices) { device in Text(device.name).tag(device.id) }
            if !value.isEmpty && !devices.contains(where: { $0.id == value }) {
                Text("Unavailable device").tag(value)
            }
        }
        .task { devices = AudioDevices.inputs() }
    }
}

// MARK: Fields

/// Saves when the user presses Return or leaves the field, like the original's inputs.
struct CommitTextField: View {
    let value: String
    var placeholder = ""
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, prompt: Text(verbatim: placeholder))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { draft = value }
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        if draft.trimmed != value { onCommit(draft.trimmed) }
    }
}

private struct SecretField: View {
    let hasValue: Bool
    let onSave: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack {
            SecureField("", text: $draft, prompt: Text(verbatim: hasValue ? "•••••••• saved" : "sk-…"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit(save)
            if !draft.isEmpty {
                Button("Save", action: save)
            } else if hasValue {
                Button("Remove", role: .destructive) { onSave("") }.buttonStyle(.link).foregroundStyle(.red)
            }
        }
    }

    private func save() {
        guard !draft.trimmed.isEmpty else { return }
        onSave(draft.trimmed)
        draft = ""
    }
}
