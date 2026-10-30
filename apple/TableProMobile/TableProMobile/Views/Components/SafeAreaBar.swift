import SwiftUI

extension View {
    func bottomSafeAreaBar<Bar: View>(spacing: CGFloat? = 0, @ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(SafeAreaBar(edge: .bottom, spacing: spacing, bar: bar()))
    }

    func topSafeAreaBar<Bar: View>(spacing: CGFloat? = 0, @ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(SafeAreaBar(edge: .top, spacing: spacing, bar: bar()))
    }
}

private struct SafeAreaBar<Bar: View>: ViewModifier {
    let edge: VerticalEdge
    let spacing: CGFloat?
    let bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: edge, spacing: spacing) { bar }
        } else {
            content.safeAreaInset(edge: edge, spacing: spacing) {
                bar.background(.bar)
            }
        }
    }
}
