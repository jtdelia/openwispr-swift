/// macOS virtual key codes, as delivered by the event tap.
public enum Key {
    public static let fn = 63
    public static let cmd = 55
    public static let cmdRight = 54
    public static let shift = 56
    public static let shiftRight = 60
    public static let opt = 58
    public static let optRight = 61
    public static let ctrl = 59
    public static let ctrlRight = 62
    public static let capsLock = 57
    public static let space = 49
    public static let esc = 53
    public static let c = 8
    public static let v = 9

    public static let modifiers: Set<Int> = [fn, cmd, cmdRight, shift, shiftRight, opt, optRight, ctrl, ctrlRight, capsLock]

    private static let labels: [Int: String] = [
        fn: "fn", cmd: "⌘", cmdRight: "Right ⌘", shift: "⇧", shiftRight: "Right ⇧", opt: "⌥", optRight: "Right ⌥",
        ctrl: "⌃", ctrlRight: "Right ⌃", capsLock: "Caps Lock", space: "Space", esc: "Esc",
        36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
    ]

    public static func label(_ keycode: Int) -> String {
        labels[keycode] ?? "Key \(keycode)"
    }

    /// Modifiers first (fn, ⌃, ⌥, ⇧, ⌘), then other keys.
    public static func comboLabel(_ combo: [Int]) -> String {
        let order = [fn, ctrl, ctrlRight, opt, optRight, shift, shiftRight, cmd, cmdRight]
        func rank(_ key: Int) -> Int { order.firstIndex(of: key) ?? order.count + key }
        return combo.sorted { rank($0) < rank($1) }.map(label).joined(separator: " + ")
    }
}
