import SwiftUI

// Not a grouped Form: a List inside one does not scroll.
struct SettingsFullPageList<Content: View, EmptyState: View, Bar: View>: View {
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
        VStack(alignment: .leading, spacing: 6) {
            content
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(maxHeight: .infinity)
                .overlay { emptyState }

            bar
        }
        .padding(20)
    }
}
