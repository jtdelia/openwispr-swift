import SwiftUI

/// The Settings window: panes listed by group in a sidebar, like System Settings.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.settingsPane) {
                ForEach(SettingsGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(group.panes) { pane in
                            Label(pane.title, systemImage: pane.symbol)
                                .tag(pane)
                                .accessibilityIdentifier("settings-\(pane.rawValue)")
                        }
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 280)
        } detail: {
            Group {
                switch model.settingsPane {
                case .general: GeneralPane()
                case .shortcuts: ShortcutsPane()
                case .speechToText: SpeechToTextPane()
                case .languageModels: LanguageModelsPane()
                case .modelLibrary: ModelLibraryPane()
                case .permissions: PermissionsPane()
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("settings-pane")
            .navigationTitle(model.settingsPane.title)
        }
        .frame(minWidth: 760, minHeight: 540)
    }
}
