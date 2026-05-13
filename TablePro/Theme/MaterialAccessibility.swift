import SwiftUI

internal enum MaterialRole {
    case banner
    case sidebar
    case toolbar
    case inlineControl
    case scrim

    var solidFallback: Color {
        switch self {
        case .banner, .toolbar, .inlineControl:
            Color(nsColor: .controlBackgroundColor)
        case .sidebar:
            Color(nsColor: .windowBackgroundColor)
        case .scrim:
            Color(nsColor: .windowBackgroundColor).opacity(0.95)
        }
    }
}

private struct AccessibleMaterialBackground: ViewModifier {
    let role: MaterialRole
    let material: Material

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
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
        if reduceTransparency || contrast == .increased {
            content.background(role.solidFallback, in: shape)
        } else {
            content.background(material, in: shape)
        }
    }
}

internal struct AccessibleMaterialScrim: View {
    let material: Material

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency || contrast == .increased {
            Rectangle().fill(MaterialRole.scrim.solidFallback)
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
