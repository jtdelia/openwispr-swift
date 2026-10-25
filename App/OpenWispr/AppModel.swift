import AppKit
import OpenWisprCore
import OpenWisprEngines
import ServiceManagement

enum Page: String, CaseIterable, Identifiable {
    case home, notetaker, dictionary, snippets, style

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .notetaker: "Notetaker"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .style: "Style"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .notetaker: "waveform.and.person.filled"
        case .dictionary: "character.book.closed"
        case .snippets: "text.badge.plus"
        case .style: "textformat"
        }
    }
}

/// A page of the Settings window, listed in its sidebar under a `SettingsGroup`.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcuts, speechToText, languageModels, modelLibrary, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .speechToText: "Speech-to-Text"
        case .languageModels: "Language Models"
        case .modelLibrary: "Model Library"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .shortcuts: "keyboard"
        case .speechToText: "mic"
        case .languageModels: "brain"
        case .modelLibrary: "shippingbox"
        case .permissions: "lock.shield"
        }
    }
}

enum SettingsGroup: String, CaseIterable, Identifiable {
    case app, models, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "App"
        case .models: "AI Models"
        case .system: "System"
        }
    }

    var panes: [SettingsPane] {
        switch self {
        case .app: [.general, .shortcuts]
        case .models: [.speechToText, .languageModels, .modelLibrary]
        case .system: [.permissions]
        }
    }
}

struct PermissionStatus: Equatable {
    var accessibility = false
    var keyTapRunning = false
    var microphone = false
}

/// Keys held while the user records a new shortcut in Settings.
struct ShortcutCapture: Equatable {
    var action: ShortcutAction
    var held: Set<Int> = []
    var combo: Set<Int> = []
}

/// The composition root: owns the stores and controllers and connects them to the Mac.
@Observable
@MainActor
final class AppModel {
    static let bundleId = "io.github.jtdelia.openwispr-swift"

    var page: Page = .home
    var settingsPane: SettingsPane = .general
    var openMeetingId: String?
    var meetingStartError: String?
    private(set) var permissions = PermissionStatus()
    private(set) var capture: ShortcutCapture?
    private(set) var builtInStatus: BuiltInStatus?
    private(set) var builtInStatusError: String?

    let isUITesting: Bool
    let store: DataStore
    let meetings: MeetingStore
    let models: Models
    let dictation: DictationController
    let notetaker: NotetakerController
    @ObservationIgnored let level: () -> Float
    @ObservationIgnored var openHub: () -> Void = {}
    @ObservationIgnored var openSettings: () -> Void = {}

    @ObservationIgnored private let shortcuts: ShortcutEngine
    @ObservationIgnored private let system: AppDictationSystem
    @ObservationIgnored private var retained: [AnyObject] = []
    @ObservationIgnored private var flowBar: FlowBarPanel?
    @ObservationIgnored private var permissionTimer: Timer?

    init(uiTesting: Bool) {
        isUITesting = uiTesting
        let directory = uiTesting ? Self.uiTestingDirectory() : Self.dataDirectory()
        let secrets: SecretStore = uiTesting ? InMemorySecretStore() : KeychainSecretStore(service: Self.bundleId)
        let store = DataStore(directory: directory, secrets: secrets)
        let modelsDirectory = directory.appending(path: "models", directoryHint: .isDirectory)
        let relay = ProgressRelay()
        let engines: any BuiltInEngines = uiTesting
            ? UITestEngines()
            : LocalEngines(modelsDirectory: modelsDirectory) { progress in await relay.report(progress) }
        let models = Models(
            settings: { store.settings }, engines: engines, http: URLSessionHTTPClient(), modelsDirectory: modelsDirectory,
            hubCache: uiTesting ? nil : .standard()
        )
        relay.models = models
        let meetings = MeetingStore(directory: directory)
        let shortcuts = ShortcutEngine(shortcuts: store.settings.shortcuts)
        let system = AppDictationSystem(store: store, uiTesting: uiTesting)
        let dictation = DictationController(store: store, models: models, system: system, engine: shortcuts)
        let speakers: SpeakerDetector = uiTesting ? UITestSpeakers() : SpeakerPoller()
        let notetaker = NotetakerController(store: store, models: models, meetings: meetings, speakers: speakers)

        if uiTesting {
            let recorder = UITestDictationRecorder()
            let meetingRecorder = UITestMeetingRecorder()
            recorder.controller = dictation
            meetingRecorder.controller = notetaker
            dictation.recorder = recorder
            notetaker.recorder = meetingRecorder
            level = { recorder.level }
            retained = [recorder, meetingRecorder, speakers]
        } else {
            let recorder = MicDictationRecorder()
            let meetingRecorder = MeetingAudioRecorder()
            recorder.controller = dictation
            meetingRecorder.controller = notetaker
            dictation.recorder = recorder
            notetaker.recorder = meetingRecorder
            level = { recorder.level }
            retained = [recorder, meetingRecorder, speakers]
        }

        self.store = store
        self.meetings = meetings
        self.models = models
        self.dictation = dictation
        self.notetaker = notetaker
        self.shortcuts = shortcuts
        self.system = system
        system.showSettingsAction = { [weak self] in self?.showSettings(.speechToText) }
    }

    func launch() {
        applyAppearance()
        flowBar = FlowBarPanel(model: self)
        if !isUITesting {
            KeyTap.shared.onKey = { [weak self] keycode, down in self?.handleKey(keycode, down: down) }
            KeyTap.shared.onReset = { [weak self] in self?.shortcuts.clearHeld() }
            KeyTap.shared.start()
        }
        dictation.syncShortcuts()
        dictation.refreshFlowBar()
        refreshPermissions()
        // Accessibility can be granted at any time in System Settings; pick it up without a restart.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        Task {
            await models.refresh()
            models.warmUp()
            await refreshBuiltInStatus()
            await models.refreshCachedModels()
        }
    }

    func terminate() async {
        store.flush()
        meetings.flush()
        await models.stop()
    }

    // MARK: Navigation

    func show(_ page: Page) {
        self.page = page
        openHub()
        NSApp.activate()
    }

    /// Opens the Settings window, on `pane` if given or else where the user left it.
    func showSettings(_ pane: SettingsPane? = nil) {
        if let pane { settingsPane = pane }
        openSettings()
        NSApp.activate()
    }

    // MARK: Settings

    func updateSettings(_ change: (inout Settings) -> Void) {
        let before = store.settings
        store.updateSettings(change)
        let settings = store.settings
        shortcuts.setShortcuts(settings.shortcuts)
        dictation.syncShortcuts()
        dictation.refreshFlowBar()
        if settings.launchAtLogin != before.launchAtLogin { setLaunchAtLogin(settings.launchAtLogin) }
        if settings.appearance != before.appearance { applyAppearance() }
        if settings.language != before.language || settings.speechToText != before.speechToText || settings.chat != before.chat {
            Task { await refreshBuiltInStatus() }
        }
    }

    func updateSelection(_ role: ModelRole, _ patch: ModelSelectionPatch) {
        store.updateSelection(role, patch)
        Task { await refreshBuiltInStatus() }
    }

    func refreshBuiltInStatus() async {
        do {
            builtInStatus = try await models.status()
            builtInStatusError = nil
        } catch {
            builtInStatusError = errorMessage(error)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard !isUITesting else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            print("openwispr: launch at login: \(error)")
        }
    }

    /// Sets the appearance app-wide, so the hub and the menu bar menu match. The Flow bar stays dark.
    private func applyAppearance() {
        switch store.settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        if isUITesting {
            permissions = PermissionStatus(accessibility: true, keyTapRunning: true, microphone: true)
            return
        }
        let trusted = Accessibility.isTrusted()
        if trusted && !KeyTap.shared.isRunning { KeyTap.shared.start() }
        permissions = PermissionStatus(accessibility: trusted, keyTapRunning: KeyTap.shared.isRunning, microphone: MicrophonePermission.granted)
    }

    func requestAccessibility() {
        _ = Accessibility.isTrusted(prompt: true)
        refreshPermissions()
    }

    func requestMicrophone() async -> Bool {
        let granted = await MicrophonePermission.request()
        refreshPermissions()
        return granted
    }

    // MARK: Shortcuts

    func startCapture(_ action: ShortcutAction) {
        capture = ShortcutCapture(action: action)
        shortcuts.clearHeld()
        KeyTap.shared.setSwallowedCombos([])
    }

    func cancelCapture() {
        capture = nil
        shortcuts.clearHeld()
        dictation.syncShortcuts()
    }

    private func handleKey(_ keycode: Int, down: Bool) {
        guard var current = capture else {
            for gesture in shortcuts.handleKey(keycode, down: down) { dictation.handleGesture(gesture) }
            return
        }
        if down {
            current.held.insert(keycode)
            current.combo.insert(keycode)
            capture = current
            return
        }
        current.held.remove(keycode)
        guard current.held.isEmpty else {
            capture = current
            return
        }
        let keys = Array(current.combo)
        let valid = !keys.isEmpty && (current.action == .ptt || keys.contains { !Key.modifiers.contains($0) } || keys.count > 1)
        if valid { updateSettings { $0.shortcuts[current.action] = keys } }
        cancelCapture()
    }

    // MARK: Notetaker

    func newMeeting() {
        let meeting = meetings.create()
        openMeetingId = meeting.id
        startRecording(meeting.id)
    }

    func startRecording(_ meetingId: String) {
        meetingStartError = nil
        Task {
            if !isUITesting {
                if MicrophonePermission.undetermined { _ = await requestMicrophone() }
                guard MicrophonePermission.granted else {
                    meetingStartError = "OpenWispr can't use the microphone. \(CaptureError.microphoneDenied.localizedDescription)"
                    return
                }
            }
            do {
                try notetaker.start(meetingId)
            } catch {
                meetingStartError = errorMessage(error)
            }
        }
    }

    func deleteMeeting(_ id: String) {
        notetaker.discard(id)
        meetings.delete(id)
        if openMeetingId == id { openMeetingId = nil }
    }

    // MARK: Data

    private static func dataDirectory() -> URL {
        let support = URL.applicationSupportDirectory
        let directory = support.appending(path: "OpenWispr-Swift", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: directory.path) {
            importElectronData(from: support.appending(path: "OpenWispr", directoryHint: .isDirectory), to: directory)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Carries settings, history, meetings and downloaded models over from the Electron app on first launch.
    /// APFS clones the files, so even large models take no extra space. Copies land in a staging folder
    /// that moves into place only once everything copied, so a failed import is retried on the next launch.
    private static func importElectronData(from source: URL, to directory: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return }
        let staging = directory.deletingLastPathComponent().appending(path: "OpenWispr-Swift.importing", directoryHint: .isDirectory)
        do {
            try? manager.removeItem(at: staging)
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in ["openwispr.json", "history.json", "meetings.json", "meetings", "models"] {
                let from = source.appending(path: name)
                guard manager.fileExists(atPath: from.path) else { continue }
                try manager.copyItem(at: from, to: staging.appending(path: name))
            }
            try manager.moveItem(at: staging, to: directory)
        } catch {
            print("openwispr: couldn't import the Electron app's data: \(error)")
            try? manager.removeItem(at: staging)
        }
    }

    private static func uiTestingDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "openwispr-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Hands engine progress to `Models`, which is created after the engines it reports for.
@MainActor
private final class ProgressRelay {
    weak var models: Models?

    func report(_ progress: ModelProgress) {
        models?.report(progress)
    }
}
