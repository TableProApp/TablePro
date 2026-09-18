import SwiftUI

extension View {
    func bottomSafeAreaBar<Bar: View>(spacing: CGFloat? = 0, @ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(BottomSafeAreaBar(spacing: spacing, bar: bar()))
    }
}

private struct BottomSafeAreaBar<Bar: View>: ViewModifier {
    let spacing: CGFloat?
    let bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom, spacing: spacing) { bar }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: spacing) {
                bar.background(.bar)
            }
        }
    }
}
