//
//  EditorTabStripSurfaces.swift
//  TablePro
//

import SwiftUI

/// Read off the system's own tab bar rather than chosen. Every value is a semantic `NSColor` so
/// the light appearance inverts with the system instead of needing a second hand-tuned palette.
///
/// These are also what the strip falls back to when it may not use glass at all, which is why the
/// selected fill is a tone of its own rather than the track's. Sharing one constant between the
/// two is what left a background window with no selection: both resolved to opaque rgb(220) in
/// light and rgb(70) in dark, a delta of exactly zero.
internal enum EditorTabStripPalette {
    /// An opaque tone rather than an alpha wash for the same reason the system's material is:
    /// measured at rgb(220) light and rgb(70) dark, against a system track of rgb(228) and
    /// rgb(77), it is the closest system colour that stays lighter than the chrome in both.
    internal static var trackFill: Color { Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }
    /// Measured at rgb(255) light and rgb(115) dark over the track, so the selected tab stands
    /// 35 and 45 levels clear of it whether or not the window is in front. The system keeps its
    /// own selected tab drawn in a background window too; only the labels step down.
    internal static var selectedFill: Color { Color(nsColor: .controlColor) }
    /// Half the weight of a separator. `separatorColor` was twice the measured edge and read as a
    /// drawn outline rather than the lit rim the system puts there.
    internal static var trackEdge: Color { Color(nsColor: .quinaryLabelColor) }
    internal static var hoverFill: Color { Color(nsColor: .tertiarySystemFill) }
    internal static var separator: Color { Color(nsColor: .separatorColor) }
}

/// Which of the two surface sets the strip draws.
///
/// The app resolves this from the environment. A test pins it, because a tinted `glassEffect`
/// cannot be rasterised at all: `cacheDisplay` comes back with an empty bitmap for the entire
/// hosting view, the strip's own titles and close button included, not merely for the glass.
internal enum EditorTabStripSurfaceStyle {
    case glass
    case solid
}

/// How far apart the track and the selected tab are held when both are glass.
///
/// Liquid Glass samples the backdrop beneath a stack, never the glass it sits on, so a `.regular`
/// capsule inside a `.regular` track carries no step of its own. Measured on the shipping strip,
/// the selected tab was rgb(248) against a track of rgb(250) in light, a contrast of 1.017 to 1,
/// and across a backdrop sweep the step turned over: +57 levels above black, -1 above white.
///
/// The system never stacks one material on itself. A runtime probe of `NSTabBar` on macOS 27 gives
/// an `NSSubduedGlassEffectView` track carrying plain `NSGlassEffectView` tabs, measured at
/// rgb(236) and rgb(253) in light and rgb(83) and rgb(89) in dark. `NSGlassEffectViewStyle`
/// publishes only `regular` and `clear`, so that subdued style is out of reach.
///
/// These two tints stand in for it. Both surfaces sample the same backdrop and are pushed in
/// opposite directions, so the step between them stops being a function of what the window is
/// over: measured from a black backdrop to a white one, the worst case is 1.189 to 1 in dark and
/// 1.183 to 1 in light, above the system's own 1.098 and 1.161, and the sign never turns over.
///
/// Both are neutral because `Glass.regular` discards hue: a red track against a green selection
/// measures exactly like no tint at all. Only lightness reaches the surface, which is what the
/// Human Interface Guidelines ask for anyway, colour on the background rather than on the text.
internal enum EditorTabStripEmphasis {
    internal static let trackTint = Color.black.opacity(0.12)
    internal static let selectionTint = Color.white.opacity(0.22)

    /// Ink rather than material, so it survives what the tints do not. macOS attenuates a glass
    /// tint in a window that is not key, measured at rgb(134) falling to rgb(94) for the selected
    /// tab, and the system's own bar gives up there too: its selected tab reads seven levels
    /// darker than its track in a background window. The rim is the part of the selection that
    /// survives, and it is a shape rather than a colour, which is the channel Apple's
    /// differentiate-without-colour criteria ask for.
    internal static var selectionEdge: Color { Color(nsColor: .separatorColor) }

    /// One device pixel on the 2x displays this chrome is drawn for.
    internal static let selectionEdgeWidth: CGFloat = 0.5

    /// Glass answers to neither Increase Contrast nor Reduce Transparency. Rendering the strip
    /// under `accessibilityHighContrastAqua` and `accessibilityHighContrastDarkAqua` produces
    /// pixels identical to plain aqua and darkAqua, measured. So the strip leaves glass behind for
    /// the opaque surfaces above, which carry 1.371 to 1 in light and 1.991 to 1 in dark.
    ///
    /// The rule itself belongs to `SolidSurfacePreference`, which the six views that reach both
    /// settings through `themeMaterial` also use. Glass has no `Material` to swap, so the strip
    /// answers the same question with a different surface rather than a second rule.
    internal static func prefersSolidSurfaces(
        reduceTransparency: Bool,
        contrast: ColorSchemeContrast
    ) -> Bool {
        SolidSurfacePreference.prefersSolid(reduceTransparency: reduceTransparency, contrast: contrast)
    }
}
