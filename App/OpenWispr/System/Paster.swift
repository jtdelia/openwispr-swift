import AppKit
import Carbon.HIToolbox

/// Inserts text by placing it on the pasteboard and synthesizing Cmd+V, then restores the user's previous
/// clipboard once the target app has had time to read it.
@MainActor
enum Paster {
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let restoreDelay = Duration.milliseconds(500)

    static func paste(_ text: String, restoreClipboard: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = restoreClipboard ? snapshot(pasteboard) : []

        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType], owner: nil)
        guard pasteboard.setString(text, forType: .string) else { return false }
        pasteboard.setString("", forType: concealedType)
        let ourChangeCount = pasteboard.changeCount

        postCommandV()

        if restoreClipboard {
            Task {
                try? await Task.sleep(for: restoreDelay)
                // If something else wrote to the clipboard meanwhile, leave it alone.
                guard pasteboard.changeCount == ourChangeCount else { return }
                restore(saved, to: pasteboard)
            }
        }
        return true
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        })
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
