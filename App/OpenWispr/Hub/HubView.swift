import SwiftUI

struct HubView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Page.allCases, selection: $model.page) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
                    .accessibilityIdentifier("nav-\(page.rawValue)")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SettingsNavRow { model.showSettings() }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch model.page {
            case .home: HomePage()
            case .notetaker: NotetakerPage()
            case .dictionary: DictionaryPage()
            case .snippets: SnippetsPage()
            case .style: StylePage()
            }
        }
        .navigationTitle("OpenWispr")
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            model.openHub = { openWindow(id: OpenWisprApp.hubWindowId) }
            model.openSettings = { openSettings() }
        }
    }
}

/// A sidebar-styled row pinned below the list that opens the Settings window instead of selecting a page.
private struct SettingsNavRow: View {
    let action: () -> Void
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.sidebarRowSize) private var sidebarRowSize

    var body: some View {
        let dimmed = controlActiveState == .inactive
        let metrics = Metrics(sidebarRowSize)
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: "gearshape")
                    .imageScale(.large)
                    .foregroundStyle(dimmed ? Color(nsColor: .tertiaryLabelColor) : .accentColor)
                    .frame(width: metrics.iconColumn, alignment: .leading)
                Text("Settings")
            }
            .font(.system(size: metrics.fontSize))
            .foregroundStyle(Color(nsColor: dimmed ? .secondaryLabelColor : .textColor))
            .frame(maxWidth: .infinity, minHeight: metrics.height, alignment: .leading)
            .padding(.leading, 8.5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .accessibilityIdentifier("nav-settings")
    }

    /// The sidebar list's row metrics for each sidebar icon size in System Settings, measured from screenshots.
    private struct Metrics {
        let fontSize: CGFloat
        let iconColumn: CGFloat
        let height: CGFloat

        init(_ size: SidebarRowSize) {
            switch size {
            case .small: (fontSize, iconColumn, height) = (11, 23.5, 24)
            case .large: (fontSize, iconColumn, height) = (15, 30, 40)
            default: (fontSize, iconColumn, height) = (13, 27.5, 32)
            }
        }
    }
}
