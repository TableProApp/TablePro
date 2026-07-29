import SwiftUI

private struct SidebarListLayout: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .safeAreaPadding(.top, 0)
            .environment(\.defaultMinListHeaderHeight, 0)
    }
}

extension View {
    func sidebarListLayout() -> some View {
        modifier(SidebarListLayout())
    }
}
