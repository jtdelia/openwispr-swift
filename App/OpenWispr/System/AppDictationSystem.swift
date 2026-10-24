import AppKit
import OpenWisprCore

/// The Mac as Dictation reaches it. In UI testing it pastes into an in-app record instead of other apps.
@MainActor
final class AppDictationSystem: DictationSystem {
    var showSettingsAction: () -> Void = {}
    private(set) var pasted: [String] = []

    private let store: DataStore
    private let uiTesting: Bool
    private lazy var sounds = SoundPlayer()

    init(store: DataStore, uiTesting: Bool) {
        self.store = store
        self.uiTesting = uiTesting
    }

    func appInfo() async -> AppInfo {
        uiTesting ? AppInfo(appName: "TextEdit", bundleId: "com.apple.TextEdit", windowTitle: "Untitled") : Accessibility.appInfo()
    }

    func textBoxInfo() async -> TextBoxInfo? {
        if uiTesting { return TextBoxInfo(accessibilityIsFunctioning: true, couldNotGetTextBoxInfo: false, isEditable: true, beforeText: "") }
        return await Task.detached { Accessibility.textBoxInfo() }.value
    }

    func paste(_ text: String, restoreClipboard: Bool) async -> Bool {
        if uiTesting {
            pasted.append(text)
            return true
        }
        return Paster.paste(text, restoreClipboard: restoreClipboard)
    }

    func copy(_ text: String) {
        Paster.copy(text)
    }

    func setSwallowedCombos(_ combos: [[Int]]) {
        KeyTap.shared.setSwallowedCombos(combos)
    }

    func play(_ sound: Sound) {
        guard store.settings.sounds, !uiTesting else { return }
        sounds.play(sound)
    }

    func showSettings() {
        showSettingsAction()
    }
}
