import AppKit
import OpenWisprCore
import SwiftUI

/// The always-on-top pill at the bottom of the screen. It never takes focus, so dictation keeps pasting
/// into the app the user is in, and it only catches the mouse while the pointer is over the pill.
@MainActor
final class FlowBarPanel {
    static let size = CGSize(width: 360, height: 96)

    private let panel: NSPanel
    private let hover = FlowBarHover()
    private var monitors: [Any] = []
    private var lastState: FlowBarState?
    private let tracksMouse: Bool

    init(model: AppModel) {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Light glass reads as a solid white blob over other apps, so the pill stays dark in every appearance.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = false
        // XCUITest clicks without hovering first, so under test the panel always takes the mouse.
        tracksMouse = !model.isUITesting
        panel.ignoresMouseEvents = tracksMouse
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityIdentifier("flow-bar")
        let host = NSHostingView(rootView: FlowBarView(model: model, hover: hover))
        host.frame = CGRect(origin: .zero, size: Self.size)
        host.sizingOptions = []
        panel.contentView = host

        let track: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.trackMouse() } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: track) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            track(event)
            return event
        }) { monitors.append(local) }

        observe(model)
    }

    private func observe(_ model: AppModel) {
        withObservationTracking {
            update(model.dictation.flowBarState)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe(model) }
        }
    }

    private func update(_ state: FlowBarState) {
        defer { lastState = state }
        if case .hidden = state {
            panel.orderOut(nil)
            return
        }
        // Follow the user to the display they're working on whenever the bar wakes up.
        if !panel.isVisible || (state.isActive && !(lastState?.isActive ?? false)) { position() }
        panel.orderFrontRegardless()
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 4))
    }

    private func trackMouse() {
        guard panel.isVisible, tracksMouse else { return }
        let point = NSEvent.mouseLocation
        let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        let inside = hover.pillFrame.insetBy(dx: -6, dy: -6).contains(local)
        panel.ignoresMouseEvents = !inside
        if hover.isHovered != inside { hover.isHovered = inside }
    }
}

/// Where the pill is drawn inside the panel, and whether the pointer is over it.
@Observable
@MainActor
final class FlowBarHover {
    var isHovered = false
    @ObservationIgnored var pillFrame: CGRect = .zero
}
