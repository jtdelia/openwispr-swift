import Foundation

public enum Gesture: Sendable, Equatable {
    case pttStart
    case pttEnd
    /// Another key joined the push-to-talk key right away: the user was typing a key combo, not dictating.
    case pttAbort
    case handsFreeStart
    /// Push-to-talk was upgraded to hands-free while held (e.g. fn, then Space).
    case handsFreeLock
    case handsFreeStop
    case dismiss
    case pasteLast
    case copyLast
}

public enum GestureMode: Sendable, Equatable {
    case idle, ptt, handsFree
}

/// Keys pressed within this window after push-to-talk starts mean the user was using a key combo.
public let pttAbortWindowMs: Double = 500

/// Turns the raw key stream from the event tap into dictation gestures. It tracks only keyboard
/// state; the dictation controller decides what a gesture means given the current dictation phase.
public final class ShortcutEngine {
    private var held = Set<Int>()
    private var mode: GestureMode = .idle
    /// Set after a one-shot gesture so nothing else fires until every key is released.
    private var suppressed = false
    private var pttStartedAt: Double = 0
    private var shortcuts: Shortcuts
    private let now: () -> Double

    public init(shortcuts: Shortcuts, now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.shortcuts = shortcuts
        self.now = now
    }

    public var gestureMode: GestureMode { mode }

    public func setShortcuts(_ shortcuts: Shortcuts) {
        self.shortcuts = shortcuts
    }

    /// Called when dictation ends without a keyboard gesture (click, error, Esc, time limit).
    public func reset() {
        mode = .idle
        suppressed = !held.isEmpty
    }

    /// The tap was re-enabled and may have missed key-ups.
    public func clearHeld() {
        held.removeAll()
        suppressed = false
    }

    public func handleKey(_ keycode: Int, down: Bool) -> [Gesture] {
        down ? keyDown(keycode) : keyUp(keycode)
    }

    private func matches(_ combo: [Int]) -> Bool {
        !combo.isEmpty && combo.count == held.count && combo.allSatisfy(held.contains)
    }

    private func keyDown(_ keycode: Int) -> [Gesture] {
        if held.contains(keycode) { return [] }
        held.insert(keycode)
        switch mode {
        case .ptt:
            if keycode == Key.esc { return endWith(.dismiss) }
            if matches(shortcuts.handsFree) {
                mode = .handsFree
                return [.handsFreeLock]
            }
            if !shortcuts.ptt.contains(keycode) && now() - pttStartedAt < pttAbortWindowMs {
                return endWith(.pttAbort)
            }
            return []
        case .handsFree:
            if keycode == Key.esc { return endWith(.dismiss) }
            if matches(shortcuts.ptt) || matches(shortcuts.handsFree) { return endWith(.handsFreeStop) }
            return []
        case .idle:
            if keycode == Key.esc && held.count == 1 { return [.dismiss] }
            if suppressed { return [] }
            if matches(shortcuts.ptt) {
                mode = .ptt
                pttStartedAt = now()
                return [.pttStart]
            }
            if matches(shortcuts.handsFree) {
                mode = .handsFree
                suppressed = true
                return [.handsFreeStart]
            }
            if matches(shortcuts.pasteLast) { return oneShot(.pasteLast) }
            if matches(shortcuts.copyLast) { return oneShot(.copyLast) }
            return []
        }
    }

    private func keyUp(_ keycode: Int) -> [Gesture] {
        held.remove(keycode)
        if held.isEmpty { suppressed = false }
        if mode == .ptt && shortcuts.ptt.contains(keycode) {
            mode = .idle
            suppressed = !held.isEmpty
            return [.pttEnd]
        }
        return []
    }

    private func endWith(_ gesture: Gesture) -> [Gesture] {
        mode = .idle
        suppressed = true
        return [gesture]
    }

    private func oneShot(_ gesture: Gesture) -> [Gesture] {
        suppressed = true
        return [gesture]
    }
}
