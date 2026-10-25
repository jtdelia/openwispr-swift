import SwiftUI

struct HubView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private static let pages = Page.allCases.filter { $0 != .settings }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Self.pages, selection: $model.page) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
                    .accessibilityIdentifier("nav-\(page.rawValue)")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PinnedNavRow(page: .settings, selection: $model.page)
            }
            // Settings isn't in the list, so the arrow keys cross into and out of it here, whether the list
            // or the pinned row has keyboard focus.
            .onKeyPress(.downArrow) {
                guard model.page == Self.pages.last || model.page == .settings else { return .ignored }
                model.page = .settings
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard model.page == .settings, let last = Self.pages.last else { return .ignored }
                model.page = last
                return .handled
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
}

/// A sidebar row pinned below the list. It draws its own selection: a second `List` would show it in the
/// unfocused gray, since clicking or arrowing into it leaves keyboard focus in the main list.
private struct PinnedNavRow: View {
    let page: Page
    @Binding var selection: Page
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.sidebarRowSize) private var sidebarRowSize

    var body: some View {
        let selected = selection == page
        let emphasized = selected && controlActiveState == .key
        let dimmed = controlActiveState == .inactive
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        let metrics = Metrics(sidebarRowSize)
        Button {
            selection = page
        } label: {
            HStack(spacing: 0) {
                Image(systemName: page.symbol)
                    .imageScale(.large)
                    .foregroundStyle(emphasized ? selectedText : dimmed ? Color(nsColor: .tertiaryLabelColor) : .accentColor)
                    .frame(width: metrics.iconColumn, alignment: .leading)
                Text(page.title)
                    .fontWeight(selected ? .semibold : .regular)
            }
            .font(.system(size: metrics.fontSize))
            .foregroundStyle(emphasized ? selectedText : Color(nsColor: dimmed ? .secondaryLabelColor : .textColor))
            .frame(maxWidth: .infinity, minHeight: metrics.height, alignment: .leading)
            .padding(.leading, 8.5)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10)
                        // The sidebar list fills its selection with the accent color, not selectedContentBackgroundColor.
                        .fill(emphasized ? Color.accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .accessibilityIdentifier("nav-\(page.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
