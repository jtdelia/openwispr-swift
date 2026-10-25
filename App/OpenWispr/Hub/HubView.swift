import SwiftUI

struct HubView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Page.allCases.filter { $0 != .settings }, selection: $model.page, rowContent: navRow)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    List([Page.settings], selection: $model.page, rowContent: navRow)
                        .scrollDisabled(true)
                        .frame(height: 44)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch model.page {
            case .home: HomePage()
            case .notetaker: NotetakerPage()
            case .dictionary: DictionaryPage()
            case .snippets: SnippetsPage()
            case .style: StylePage()
            case .settings: SettingsPage()
            }
        }
        .navigationTitle("OpenWispr")
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            model.openHub = { openWindow(id: OpenWisprApp.hubWindowId) }
        }
    }

    private func navRow(_ page: Page) -> some View {
        Label(page.title, systemImage: page.symbol)
            .tag(page)
            .accessibilityIdentifier("nav-\(page.rawValue)")
    }
}
