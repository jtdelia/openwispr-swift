import AppKit
import ApplicationServices
import OpenWisprCore

enum Accessibility {
    static func isTrusted(prompt: Bool = false) -> Bool {
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 won't read from a global var.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frontmostAppElement() -> (NSRunningApplication, AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium and Electron apps only build their AX tree when asked to.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return (app, element)
    }

    static func appInfo() -> AppInfo {
        guard let (app, element) = frontmostAppElement() else { return .unknown }
        var title = ""
        if let windowRef = attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(windowRef) == AXUIElementGetTypeID(),
           let value = attribute(unsafeDowncast(windowRef, to: AXUIElement.self), kAXTitleAttribute) as? String {
            title = value
        }
        return AppInfo(appName: app.localizedName ?? "", bundleId: app.bundleIdentifier ?? "", windowTitle: title)
    }

    static func textBoxInfo() -> TextBoxInfo {
        var info = TextBoxInfo(accessibilityIsFunctioning: isTrusted(), couldNotGetTextBoxInfo: true, isEditable: false, beforeText: "")
        _ = frontmostAppElement()
        let system = AXUIElementCreateSystemWide()
        guard let focusedRef = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return info
        }
        let focused = unsafeDowncast(focusedRef, to: AXUIElement.self)

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        let role = attribute(focused, kAXRoleAttribute) as? String ?? ""
        let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        info.isEditable = settable.boolValue || editableRoles.contains(role)

        guard let contents = attribute(focused, kAXValueAttribute) as? String else { return info }
        info.couldNotGetTextBoxInfo = false
        if let rangeRef = attribute(focused, kAXSelectedTextRangeAttribute), CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(unsafeDowncast(rangeRef, to: AXValue.self), .cfRange, &range) {
                let text = contents as NSString
                info.beforeText = text.substring(to: max(0, min(range.location, text.length)))
            }
        }
        return info
    }
}
