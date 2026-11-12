import SwiftUI
import TableProTheme

internal enum MaterialRole {
    case toolbar
    case scrim

    var solidFallback: Color {
        switch self {
        case .toolbar:
            Color(nsColor: .controlBackgroundColor)
        case .scrim:
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// The one rule for both settings, so a view that answers them by hand cannot drift from the views
/// that answer them through `themeMaterial`. The editor tab strip is that view: glass has no
/// `Material` to swap, so it leaves glass behind for its own opaque surfaces instead.
internal enum SolidSurfacePreference {
    internal static func prefersSolid(reduceTransparency: Bool, contrast: ColorSchemeContrast) -> Bool {
        reduceTransparency || contrast == .increased
    }
}

private struct AccessibleMaterialBackground: ViewModifier {
    let role: MaterialRole
    let material: Material

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if SolidSurfacePreference.prefersSolid(reduceTransparency: reduceTransparency, contrast: contrast) {
            content.background(role.solidFallback)
        } else {
            content.background(material)
        }
    }
}

private struct AccessibleMaterialBackgroundShape<S: Shape>: ViewModifier {
    let role: MaterialRole
    let material: Material
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if SolidSurfacePreference.prefersSolid(reduceTransparency: reduceTransparency, contrast: contrast) {
            content.background(role.solidFallback, in: shape)
        } else {
            content.background(material, in: shape)
        }
    }
}

// The scrim covers a detail pane, so its solid stand-in is the window color that pane sits on.
internal struct AccessibleMaterialScrim: View {
    let material: Material

    // The environment value is get-only, so a test hands its own.
    var reduceTransparency: Bool?

    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let reduceTransparency = reduceTransparency ?? systemReduceTransparency
        if SolidSurfacePreference.prefersSolid(reduceTransparency: reduceTransparency, contrast: contrast) {
            Rectangle().fill(
                ThemeShapeStyle.style(
                    .windowBackdrop,
                    native: MaterialRole.scrim.solidFallback,
                    engine: themeEngine,
                    contrast: contrast
                )
            )
        } else {
            Rectangle().fill(material)
        }
    }
}

internal extension View {
    func themeMaterial(_ role: MaterialRole, _ material: Material) -> some View {
        modifier(AccessibleMaterialBackground(role: role, material: material))
    }

    func themeMaterial<S: Shape>(_ role: MaterialRole, _ material: Material, in shape: S) -> some View {
        modifier(AccessibleMaterialBackgroundShape(role: role, material: material, shape: shape))
    }
}
