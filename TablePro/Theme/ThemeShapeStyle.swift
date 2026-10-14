import SwiftUI

/// What a SwiftUI surface draws for a slot: the theme's color while the active theme sets it, and the
/// style the surface has always drawn otherwise, passed through untouched so a default theme draws
/// exactly what it did before the theme reached that surface.
@MainActor
internal enum ThemeShapeStyle {
    internal static func override(
        _ slot: ThemeSlot,
        engine: ThemeEngine = .shared,
        contrast: ColorSchemeContrast
    ) -> Color? {
        guard engine.activeTheme.isOverridden(slot, highContrast: contrast == .increased) else { return nil }
        return Color(nsColor: engine.palette[slot])
    }

    internal static func style(
        _ slot: ThemeSlot,
        native: some ShapeStyle,
        engine: ThemeEngine = .shared,
        contrast: ColorSchemeContrast
    ) -> AnyShapeStyle {
        guard let color = override(slot, engine: engine, contrast: contrast) else { return AnyShapeStyle(native) }
        return AnyShapeStyle(color)
    }
}

/// One erased style rather than a branch, so a theme switch repaints the surface without rebuilding
/// the views inside it.
private struct ThemeBackground<Native: ShapeStyle>: ViewModifier {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.colorSchemeContrast) private var contrast

    let slot: ThemeSlot
    let native: Native
    let edges: Edge.Set

    func body(content: Content) -> some View {
        content.background(
            ThemeShapeStyle.style(slot, native: native, engine: themeEngine, contrast: contrast),
            ignoresSafeAreaEdges: edges
        )
    }
}

private struct ThemeShapeBackground<Native: ShapeStyle, Fill: Shape>: ViewModifier {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.colorSchemeContrast) private var contrast

    let slot: ThemeSlot
    let native: Native
    let shape: Fill

    func body(content: Content) -> some View {
        content.background(ThemeShapeStyle.style(slot, native: native, engine: themeEngine, contrast: contrast), in: shape)
    }
}

private struct ThemeForeground<Native: ShapeStyle>: ViewModifier {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.colorSchemeContrast) private var contrast

    let slot: ThemeSlot
    let native: Native

    func body(content: Content) -> some View {
        content.foregroundStyle(ThemeShapeStyle.style(slot, native: native, engine: themeEngine, contrast: contrast))
    }
}

internal extension View {
    func themeBackground(
        _ slot: ThemeSlot,
        native: some ShapeStyle,
        ignoresSafeAreaEdges edges: Edge.Set = .all
    ) -> some View {
        modifier(ThemeBackground(slot: slot, native: native, edges: edges))
    }

    func themeBackground(_ slot: ThemeSlot, native: some ShapeStyle, in shape: some Shape) -> some View {
        modifier(ThemeShapeBackground(slot: slot, native: native, shape: shape))
    }

    /// For one text or shape. A row that can be selected keeps a hierarchical style instead: a fixed
    /// color does not turn white on the emphasized selection the way `.primary` does.
    func themeForeground(_ slot: ThemeSlot, native: some ShapeStyle) -> some View {
        modifier(ThemeForeground(slot: slot, native: native))
    }
}
