//
//  QuickSwitcherSurface.swift
//  TablePro
//

import AppKit
import SwiftUI

internal enum QuickSwitcherMetrics {
    static let width: CGFloat = 640
    static let inputRowHeight: CGFloat = 52
    static let rowHeight: CGFloat = 44
    static let rowInset: CGFloat = 8
    static let iconContainerSize: CGFloat = 26
    static let sectionHeaderHeight: CGFloat = 30
    static let listVerticalPadding: CGFloat = 6
    static let footerHeight: CGFloat = 34
    static let scopeBarHeight: CGFloat = 38
    static let maxVisibleRows = 9

    /// Liquid Glass asks for a much larger radius than the pre-26 popover look, and the panel is
    /// the app's only free-floating surface, so it carries the full capsule-adjacent curvature.
    static var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) {
            return 26
        }
        return 12
    }

    /// Concentric with the surface: a shape inset by `rowInset` keeps a constant border width to
    /// the surface only when its radius drops by the same amount.
    static var rowCornerRadius: CGFloat {
        max(6, cornerRadius - rowInset)
    }
}

/// The panel's background.
///
/// macOS 26 draws it with the real Liquid Glass, through SwiftUI's own modifier rather than a
/// hand-placed `NSGlassEffectView`. `NSGlassEffectView` documents that "only ... the `contentView`
/// will be placed inside the glass effect; arbitrary subviews aren't guaranteed specific behavior
/// with regard to z-order", so using one as a bare `.background()` with the real content as
/// siblings, then clipping it from outside and stroking a border over it, is off-contract: glass
/// owns its own shape and its own edge treatment. Measured on macOS 27: the SwiftUI modifier paints
/// correctly inside this panel's borderless, `isOpaque = false`, clear-backed window, and reads as
/// materially more transparent than the view it replaces.
internal struct QuickSwitcherSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let cornerRadius: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// Glass draws its own edge. Below macOS 26 the material does not, and the border is the only
    /// thing separating the panel from whatever it floats over, so it strengthens with the system
    /// contrast setting the way the old hand-rolled chrome did.
    private var borderColor: Color {
        colorSchemeContrast == .increased
            ? Color(nsColor: .separatorColor)
            : Color(nsColor: .separatorColor).opacity(0.6)
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(BehindWindowMaterial())
                .clipShape(shape)
                .overlay(shape.strokeBorder(borderColor, lineWidth: 0.5))
        }
    }
}

/// SwiftUI's `.regularMaterial` blends against what is behind it *inside the window*, and this
/// panel's window is borderless, `isOpaque = false` and clear-backed, so there is nothing in the
/// window for it to sample: it would render as a flat wash over the desktop rather than a blurred
/// popover. `NSVisualEffectView` with `.behindWindow` is the only thing that samples the desktop,
/// which is what the chrome this replaced used and what every user below macOS 26 still gets.
private struct BehindWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Groups every glass shape the panel draws into one rendering pass. Without it each shape samples
/// the desktop independently and they read as unrelated slabs instead of one surface.
internal struct QuickSwitcherGlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
    }
}

internal extension View {
    func quickSwitcherSurface(cornerRadius: CGFloat) -> some View {
        modifier(QuickSwitcherSurface(cornerRadius: cornerRadius))
    }
}
