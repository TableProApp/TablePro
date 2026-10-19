import SwiftUI
import TableProTheme

internal extension View {
    /// The rounded, bordered well a stored value sits in, on the editor's background while the active
    /// theme sets it. `clipsContent` is for a view that paints its own background, which the well
    /// clips to its corners; text drawn straight on the well gets the text background instead.
    func valueWell(clipsContent: Bool = false) -> some View {
        modifier(ValueWell(clipsContent: clipsContent))
    }

    /// The inset text takes inside the well, so a read-only value and `ValueTextField` line up.
    func valueWellPadding() -> some View {
        padding(.horizontal, ValueWellMetrics.textInset.width)
            .padding(.vertical, ValueWellMetrics.textInset.height)
    }
}

/// Shared with `ValueTextField`, whose focus ring has to hug the well's own shape.
internal enum ValueWellMetrics {
    static let cornerRadius: CGFloat = 5
    static let textInset = CGSize(width: 6, height: 4)
}

private struct ValueWell: ViewModifier {
    let clipsContent: Bool

    private static let shape = RoundedRectangle(cornerRadius: ValueWellMetrics.cornerRadius)

    @ViewBuilder
    func body(content: Content) -> some View {
        if clipsContent {
            content
                .themeBackground(.editorBackground, native: Color.clear, in: Self.shape)
                .clipShape(Self.shape)
                .overlay(Self.border)
        } else {
            content
                .themeBackground(.editorBackground, native: Color(nsColor: .textBackgroundColor), in: Self.shape)
                .overlay(Self.border)
        }
    }

    private static var border: some View {
        shape.strokeBorder(Color(nsColor: .separatorColor))
    }
}
