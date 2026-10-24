import Testing
@testable import OpenWisprCore

private final class Harness {
    var time = 0.0
    lazy var engine = ShortcutEngine(shortcuts: .defaults, now: { [unowned self] in time })

    func advance(_ ms: Double) { time += ms }
    func down(_ key: Int) -> [Gesture] { engine.handleKey(key, down: true) }
    func up(_ key: Int) -> [Gesture] { engine.handleKey(key, down: false) }
}

struct ShortcutEngineTests {
    @Test func startsAndEndsPushToTalkOnFnHold() {
        let h = Harness()
        #expect(h.down(Key.fn) == [.pttStart])
        h.advance(2000)
        #expect(h.up(Key.fn) == [.pttEnd])
    }

    @Test func locksIntoHandsFreeWhenSpaceJoinsFnThenStopsOnTheNextFnPress() {
        let h = Harness()
        #expect(h.down(Key.fn) == [.pttStart])
        #expect(h.down(Key.space) == [.handsFreeLock])
        #expect(h.up(Key.space) == [])
        #expect(h.up(Key.fn) == [])
        #expect(h.engine.gestureMode == .handsFree)
        #expect(h.down(Key.fn) == [.handsFreeStop])
        #expect(h.up(Key.fn) == [])
        #expect(h.engine.gestureMode == .idle)
    }

    @Test func abortsPushToTalkWhenFnIsUsedAsAModifier() {
        let h = Harness()
        _ = h.down(Key.fn)
        h.advance(100)
        #expect(h.down(126) == [.pttAbort])
        #expect(h.up(126) == [])
        #expect(h.up(Key.fn) == [])
        #expect(h.down(Key.fn) == [.pttStart])
    }

    @Test func ignoresStrayKeysOncePushToTalkIsEstablished() {
        let h = Harness()
        _ = h.down(Key.fn)
        h.advance(pttAbortWindowMs + 1)
        #expect(h.down(126) == [])
        #expect(h.up(Key.fn) == [.pttEnd])
    }

    @Test func dismissesWithEscWhileRecording() {
        let h = Harness()
        _ = h.down(Key.fn)
        #expect(h.down(Key.esc) == [.dismiss])
        #expect(h.engine.gestureMode == .idle)
    }

    @Test func firesPasteLastOncePerPress() {
        let h = Harness()
        #expect(h.down(Key.ctrl) == [])
        #expect(h.down(Key.cmd) == [])
        #expect(h.down(Key.v) == [.pasteLast])
        _ = h.up(Key.v)
        #expect(h.down(Key.v) == [])
    }

    @Test func ignoresKeyRepeats() {
        let h = Harness()
        #expect(h.down(Key.fn) == [.pttStart])
        #expect(h.down(Key.fn) == [])
    }

    @Test func labelsCombos() {
        #expect(Key.comboLabel(Shortcuts.defaults.handsFree) == "fn + Space")
    }
}
