import Foundation
import Observation

public struct AppInfo: Sendable, Equatable {
    public var appName: String
    public var bundleId: String
    public var windowTitle: String

    public init(appName: String, bundleId: String, windowTitle: String) {
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
    }

    public static let unknown = AppInfo(appName: "", bundleId: "", windowTitle: "")
}

/// What Accessibility says about the focused text field.
public struct TextBoxInfo: Sendable, Equatable {
    public var accessibilityIsFunctioning: Bool
    /// The focused element didn't answer; many apps don't expose Accessibility.
    public var couldNotGetTextBoxInfo: Bool
    public var isEditable: Bool
    public var beforeText: String

    public init(accessibilityIsFunctioning: Bool, couldNotGetTextBoxInfo: Bool, isEditable: Bool, beforeText: String) {
        self.accessibilityIsFunctioning = accessibilityIsFunctioning
        self.couldNotGetTextBoxInfo = couldNotGetTextBoxInfo
        self.isEditable = isEditable
        self.beforeText = beforeText
    }
}

public enum Sound: String, Sendable {
    case start, stop, lock, error
}

/// The Mac as Dictation reaches it: Accessibility, the pasteboard, the event tap and sounds.
@MainActor
public protocol DictationSystem: AnyObject {
    func appInfo() async -> AppInfo
    func textBoxInfo() async -> TextBoxInfo?
    /// Pastes `text` into the focused app; false when it couldn't.
    func paste(_ text: String, restoreClipboard: Bool) async -> Bool
    func copy(_ text: String)
    /// The event tap swallows keys that complete these combos.
    func setSwallowedCombos(_ combos: [[Int]])
    func play(_ sound: Sound)
    /// Opens the hub on Settings, e.g. when no speech-to-text model is set up.
    func showSettings()
}

/// Records one dictation. After `start`, it reports `recorderStarted` or `recorderFailed`; after `stop`,
/// it hands the 16 kHz mono WAV to `handleAudio`.
@MainActor
public protocol DictationRecorder: AnyObject {
    func start(deviceId: String)
    func stop()
    func cancel()
    /// Input level 0...1 while listening, for the Flow bar's waveform.
    var level: Float { get }
}

/// Matches Wispr Flow's DICTATION_DEBOUNCE_DELAY: shorter push-to-talk holds are treated as accidental taps.
public let pttMinHoldMs = 500.0
public let maxRecordingDuration = Duration.seconds(10 * 60)
public let noticeDuration = Duration.milliseconds(2500)
/// 16 kHz mono PCM16 WAV: 44-byte header plus ~0.25 s of audio.
public let minWavBytes = wavBytes(ms: 250)

@Observable
@MainActor
public final class DictationController {
    private struct FocusContext {
        var app: AppInfo
        var textBox: TextBoxInfo?
    }

    private enum Phase {
        case idle
        case recording(session: Int, mode: DictationMode, startedAt: Double, context: Task<FocusContext, Never>)
        case processing(session: Int, mode: DictationMode, durationMs: Double, context: Task<FocusContext, Never>)
    }

    public private(set) var flowBarState: FlowBarState = .resting

    @ObservationIgnored private let store: DataStore
    @ObservationIgnored private let models: Models
    @ObservationIgnored private let system: DictationSystem
    @ObservationIgnored private let engine: ShortcutEngine
    @ObservationIgnored public weak var recorder: DictationRecorder?
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private var phase: Phase = .idle
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var maxTimer: Task<Void, Never>?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?

    public init(store: DataStore, models: Models, system: DictationSystem, engine: ShortcutEngine, now: @escaping () -> Double = epochMs) {
        self.store = store
        self.models = models
        self.system = system
        self.engine = engine
        self.now = now
    }

    public var isActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    public func handleGesture(_ gesture: Gesture) {
        switch gesture {
        case .pttStart:
            start(.ptt)
        case .handsFreeStart:
            start(.handsFree)
        case .handsFreeLock:
            lockHandsFree()
        case .pttEnd:
            guard case let .recording(_, mode, startedAt, _) = phase, mode == .ptt else { return }
            if now() - startedAt < pttMinHoldMs { cancel() } else { stop() }
        case .handsFreeStop:
            stop()
        case .pttAbort, .dismiss:
            cancel()
        case .pasteLast:
            Task { await pasteLast() }
        case .copyLast:
            copyLast()
        }
    }

    public func start(_ mode: DictationMode) {
        guard case .idle = phase else { return }
        if case let .unavailable(reason) = models.availability(.speechToText) {
            engine.reset()
            notice(reason, .error)
            system.showSettings()
            return
        }
        models.warmUp()
        session += 1
        let context = Task { [system] in
            FocusContext(app: await system.appInfo(), textBox: await system.textBoxInfo())
        }
        phase = .recording(session: session, mode: mode, startedAt: now(), context: context)
        setFlowBar(.initializing(mode))
        recorder?.start(deviceId: store.settings.microphoneId)
        playSound(.start)
        syncShortcuts()
        maxTimer = Task { [weak self] in
            try? await Task.sleep(for: maxRecordingDuration)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func lockHandsFree() {
        guard case let .recording(session, _, startedAt, context) = phase else { return }
        phase = .recording(session: session, mode: .handsFree, startedAt: startedAt, context: context)
        setFlowBar(.listening(.handsFree))
        playSound(.lock)
    }

    public func stop() {
        guard case let .recording(session, mode, startedAt, context) = phase else { return }
        clearMaxTimer()
        phase = .processing(session: session, mode: mode, durationMs: now() - startedAt, context: context)
        engine.reset()
        setFlowBar(.processing)
        recorder?.stop()
        playSound(.stop)
        syncShortcuts()
    }

    public func cancel() {
        if case .idle = phase { return }
        clearMaxTimer()
        if case .recording = phase { recorder?.cancel() }
        phase = .idle
        engine.reset()
        setFlowBar(.resting)
        syncShortcuts()
    }

    public func recorderStarted() {
        guard case let .recording(_, mode, _, _) = phase else { return }
        setFlowBar(.listening(mode))
    }

    public func recorderFailed(_ message: String) {
        if case .idle = phase { return }
        clearMaxTimer()
        phase = .idle
        engine.reset()
        syncShortcuts()
        playSound(.error)
        notice("Microphone error: \(message)", .error)
    }

    public func handleAudio(_ wav: Data) async {
        guard case let .processing(session, mode, durationMs, context) = phase else { return }
        let isCurrent = { [weak self] () -> Bool in
            guard let self, case let .processing(current, _, _, _) = self.phase else { return false }
            return current == session
        }
        let settings = store.settings
        let focus = await context.value
        let timestamp = now()
        func entry(_ status: HistoryStatus, asrText: String, formattedText: String, error: String? = nil) -> HistoryEntry {
            HistoryEntry(
                timestamp: timestamp, mode: mode, status: status, asrText: asrText, formattedText: formattedText,
                appName: focus.app.appName, bundleId: focus.app.bundleId, durationMs: durationMs,
                numWords: countWords(formattedText), error: error
            )
        }

        if wav.count < minWavBytes {
            finish("No audio captured", .info)
            return
        }

        var asrText = ""
        do {
            asrText = try await models.transcribe(wav, prompt: transcriptionPrompt(dictionary: store.dictionary, userName: settings.userName))
            guard isCurrent() else { return }
            let (text, cleanupNotice) = asrText.isEmpty ? ("", nil) : await format(asrText, focus: focus)
            guard isCurrent() else { return }

            if text.trimmed.isEmpty {
                store.addHistory(entry(.empty, asrText: asrText, formattedText: ""))
                finish("No speech detected", .info)
                return
            }

            let formattedText = joinWithContext(text, beforeText: focus.textBox?.beforeText ?? "")
            let status = await insert(formattedText, textBox: focus.textBox)
            store.addHistory(entry(status, asrText: asrText, formattedText: formattedText.trimmed))
            let copiedMessage = focus.textBox?.accessibilityIsFunctioning == true
                ? "No text field focused. Copied to clipboard"
                : "Copied. Grant Accessibility to auto-paste"
            finish(status == .copied ? copiedMessage : cleanupNotice, .info)
        } catch {
            guard isCurrent() else { return }
            let message = errorMessage(error)
            print("openwispr: dictation failed: \(error)")
            playSound(.error)
            store.addHistory(entry(.error, asrText: asrText, formattedText: asrText, error: message))
            finish(message, .error)
        }
    }

    /// The text to insert, and why Cleanup didn't run when the user should know.
    private func format(_ asrText: String, focus: FocusContext) async -> (String, String?) {
        let dictionary = store.dictionary
        let snippets = store.snippets
        let settings = store.settings
        if let snippet = wholeSnippet(asrText, snippets: snippets) { return (snippet, nil) }

        var text = applyReplacements(asrText, dictionary: dictionary)
        var notice: String?
        if settings.cleanup.enabled, models.availability(.chat) == .available {
            let category = appCategory(bundleId: focus.app.bundleId, windowTitle: focus.app.windowTitle)
            let cleaned = await models.cleanup(CleanupInput(
                transcript: text,
                style: settings.styles[styleContext(category: category, bundleId: focus.app.bundleId, windowTitle: focus.app.windowTitle)],
                category: category, appName: focus.app.appName, beforeText: focus.textBox?.beforeText ?? "",
                dictionary: dictionary, userName: settings.userName
            ))
            text = applyReplacements(cleaned.text, dictionary: dictionary)
            notice = cleaned.notice
        }
        return (applySnippets(text, snippets: snippets), notice)
    }

    private func insert(_ text: String, textBox: TextBoxInfo?) async -> HistoryStatus {
        // Synthesized Cmd+V is silently dropped without Accessibility, so fall back to the clipboard.
        // Otherwise only skip pasting when AX positively reports a non-editable focus; many apps don't expose AX.
        let cannotPaste = textBox.map { !$0.accessibilityIsFunctioning || (!$0.couldNotGetTextBoxInfo && !$0.isEditable) } ?? true
        if !cannotPaste, await system.paste(text, restoreClipboard: store.settings.restoreClipboard) { return .pasted }
        system.copy(text.trimmed)
        return .copied
    }

    private func finish(_ message: String?, _ tone: NoticeTone) {
        phase = .idle
        syncShortcuts()
        if let message { notice(message, tone) } else { setFlowBar(.resting) }
    }

    private func pasteLast() async {
        guard let text = store.lastText(), case .idle = phase else { return }
        _ = await system.paste(text, restoreClipboard: store.settings.restoreClipboard)
    }

    private func copyLast() {
        guard let text = store.lastText() else { return }
        system.copy(text)
        notice("Copied last transcript", .info)
    }

    /// The event tap swallows keys that complete these combos; Esc is only claimed while dictating.
    public func syncShortcuts() {
        engine.setShortcuts(store.settings.shortcuts)
        system.setSwallowedCombos(store.settings.swallowedCombos(dictating: isActive))
    }

    /// Shows a short message in the Flow bar, e.g. a model download's progress.
    public func notice(_ message: String, _ tone: NoticeTone) {
        noticeTimer?.cancel()
        setFlowBar(.notice(message, tone))
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: noticeDuration)
            guard !Task.isCancelled, let self else { return }
            noticeTimer = nil
            if case .idle = phase { setFlowBar(.resting) }
        }
    }

    private func setFlowBar(_ state: FlowBarState) {
        flowBarState = store.settings.showFlowBar || state.isActive ? state : .hidden
    }

    /// Re-applies the Flow bar setting.
    public func refreshFlowBar() {
        if case .idle = phase, !flowBarState.isActive { setFlowBar(.resting) }
    }

    private func playSound(_ sound: Sound) {
        if store.settings.sounds { system.play(sound) }
    }

    private func clearMaxTimer() {
        maxTimer?.cancel()
        maxTimer = nil
    }
}
