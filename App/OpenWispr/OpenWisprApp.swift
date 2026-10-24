import AppKit
import OpenWisprCore
import SwiftUI

@main
struct OpenWisprApp: App {
    static let hubWindowId = "hub"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("OpenWispr", id: Self.hubWindowId) {
            HubView()
                .environment(delegate.model)
        }
        .defaultSize(width: 1000, height: 720)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarMenu()
                .environment(delegate.model)
        } label: {
            MenuBarLabel(notetaker: delegate.model.notetaker)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(uiTesting: ProcessInfo.processInfo.arguments.contains(uiTestingArgument))

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch()
    }

    /// Stays alive in the menu bar after the hub closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { model.openHub() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.terminate()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MenuBarLabel: View {
    let notetaker: NotetakerController

    var body: some View {
        // Recording other people should never be invisible.
        if notetaker.state.isRecording {
            Label("Notes", systemImage: "record.circle.fill").labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "waveform")
        }
    }
}

private struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open OpenWispr") { model.show(model.page) }
        Button("Start hands-free dictation") { model.dictation.start(.handsFree) }
        if model.notetaker.state.isRecording {
            Button("Stop taking meeting notes") { Task { await model.notetaker.stop() } }
        }
        Divider()
        Button("Quit OpenWispr") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
