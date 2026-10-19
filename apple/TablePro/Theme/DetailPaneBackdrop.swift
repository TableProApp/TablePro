import SwiftUI
import TableProTheme

/// Before macOS 26 the toolbar and sidebar keep the system color, so a themed backdrop stops below the toolbar.
@MainActor
internal enum DetailPaneBackdrop {
    internal static var extendsUnderToolbar: Bool {
        ThemeWindowBackdrop.canReachChrome
    }

    internal static func isThemed(contrast: ColorSchemeContrast) -> Bool {
        ThemeBackdropState.isThemed(highContrast: contrast == .increased)
    }

    internal static func safeAreaEdges(isThemed: Bool, extendsUnderToolbar: Bool) -> Edge.Set {
        isThemed && !extendsUnderToolbar ? Edge.Set.all.subtracting(.top) : .all
    }
}

internal struct DetailPaneBackdropFill: ViewModifier {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.colorSchemeContrast) private var contrast
    internal var extendsUnderToolbar = DetailPaneBackdrop.extendsUnderToolbar

    internal func body(content: Content) -> some View {
        let isThemed = DetailPaneBackdrop.isThemed(contrast: contrast)
        return content.background(
            ThemeShapeStyle.style(.windowBackdrop, native: .background, engine: themeEngine, contrast: contrast),
            ignoresSafeAreaEdges: DetailPaneBackdrop.safeAreaEdges(isThemed: isThemed, extendsUnderToolbar: extendsUnderToolbar)
        )
    }
}
