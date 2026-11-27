import AppKit
import SwiftUI

// Not a grouped Form: a List inside one does not scroll.
struct SettingsFullPageList<Content: View, EmptyState: View, Bar: View>: View {
    private static var borderWidth: CGFloat { 1 }

    private let content: Content
    private let emptyState: EmptyState
    private let bar: Bar

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder emptyState: () -> EmptyState = { EmptyView() },
        @ViewBuilder bar: () -> Bar = { EmptyView() }
    ) {
        self.content = content()
        self.emptyState = emptyState()
        self.bar = bar()
    }

    var body: some View {
        list
            .frame(maxHeight: .infinity)
            .padding(20)
    }

    @ViewBuilder
    private var list: some View {
        let bordered = content
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .overlay { emptyState }

        if Bar.self == EmptyView.self {
            bordered
        } else {
            // An inset, unlike the .listBar overlay, scrolls the last row clear of the bar.
            bordered.safeAreaInset(edge: .bottom, spacing: 0) {
                ListBar { bar }
                    // Rows scroll under the bar, so it needs the list's fill, kept inside the border.
                    .background(Color(nsColor: .controlBackgroundColor))
                    .padding([.horizontal, .bottom], Self.borderWidth)
            }
        }
    }
}
