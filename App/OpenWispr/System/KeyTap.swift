import AppKit
import CoreGraphics
import OpenWisprCore

/// Global keyboard tap. Reports every key transition and swallows a non-modifier key only when, together
/// with the held modifiers, it exactly completes a registered shortcut. Needs Accessibility.
@MainActor
final class KeyTap {
    static let shared = KeyTap()

    /// Every key transition, by virtual key code.
    var onKey: ((_ keycode: Int, _ down: Bool) -> Void)?
    /// macOS disabled the tap for a moment; held keys may have been released meanwhile.
    var onReset: (() -> Void)?

    private var tap: CFMachPort?
    private var heldModifiers = Set<Int>()
    private var swallowedKeyUps = Set<Int>()
    private var shortcuts: [Set<Int>] = []

    /// Device-dependent modifier masks from IOKit's NX_DEVICE*KEYMASK, keyed by virtual key code.
    private static let modifierMasks: [Int: UInt64] = [
        55: 0x0000_0008, // left command
        54: 0x0000_0010, // right command
        56: 0x0000_0002, // left shift
        60: 0x0000_0004, // right shift
        58: 0x0000_0020, // left option
        61: 0x0000_0040, // right option
        59: 0x0000_0001, // left control
        62: 0x0000_2000, // right control
        63: CGEventFlags.maskSecondaryFn.rawValue,
        57: CGEventFlags.maskAlphaShift.rawValue,
    ]

    var isRunning: Bool { tap != nil }

    func setSwallowedCombos(_ combos: [[Int]]) {
        shortcuts = combos.map(Set.init)
    }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        // The source is added to the main run loop, so the callback runs on the main thread.
        let callback: CGEventTapCallBack = { _, type, event, _ in
            let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue
            let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let pass = MainActor.assumeIsolated {
                KeyTap.shared.handle(type: type, keycode: keycode, flags: flags, autorepeat: autorepeat)
            }
            return pass ? Unmanaged.passUnretained(event) : nil
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: nil
        ) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// Whether the event should reach the focused app.
    private func handle(type: CGEventType, keycode: Int, flags: UInt64, autorepeat: Bool) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            heldModifiers.removeAll()
            onReset?()
            return true
        case .flagsChanged:
            guard let mask = Self.modifierMasks[keycode] else { return true }
            let down = flags & mask != 0
            if down { heldModifiers.insert(keycode) } else { heldModifiers.remove(keycode) }
            onKey?(keycode, down)
            return true
        case .keyDown, .keyUp:
            let isDown = type == .keyDown
            if !autorepeat { onKey?(keycode, isDown) }
            if isDown {
                let keys = heldModifiers.union([keycode])
                if shortcuts.contains(keys) || shortcuts.contains(keys.subtracting([Key.capsLock])) {
                    swallowedKeyUps.insert(keycode)
                    return false
                }
                return !swallowedKeyUps.contains(keycode)
            }
            return swallowedKeyUps.remove(keycode) == nil
        default:
            return true
        }
    }
}
