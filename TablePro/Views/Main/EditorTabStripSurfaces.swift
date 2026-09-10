//
//  EditorTabStripSurfaces.swift
//  TablePro
//

import SwiftUI

/// The strip's surfaces.
///
/// Every value is a semantic `NSColor`, so the light appearance inverts with the system instead of
/// needing a second hand-tuned palette, and so nothing here has to be retuned when Apple moves a
/// tone. The pair was checked against the system's own tab bar rather than chosen: `NSTabBar`
/// measures a track of rgb(232) and a selected tab of rgb(253) in light, and rgb(71) and rgb(74)
/// in dark. These resolve to rgb(220) and rgb(255) in light, and rgb(70) and rgb(116) in dark.
internal enum EditorTabStripPalette {
    /// Measured at rgb(220) light and rgb(70) dark. The system's own tab track measures rgb(232)
    /// and rgb(71), so this is within a level of it in dark and slightly deeper in light.
    internal static var trackFill: Color { Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }

    /// Opaque white in light, and white at alpha 0.247 in dark. That asymmetry is the whole reason
    /// the selection cannot invert: in light it is the ceiling, so no track can rise above it, and
    /// in dark it composites *over* whatever the track resolved to, so it always lifts. The step
    /// is a property of the colour rather than of a tuned distance.
    internal static var selectedFill: Color { Color(nsColor: .controlColor) }

    /// Half the weight of a separator. `separatorColor` was twice the measured edge and read as a
    /// drawn outline rather than the lit rim the system puts there.
    ///
    /// `quinaryLabel`, not `quinaryLabelColor`. The two spellings swap places between toolchains:
    /// the Xcode 27 beta deprecates this one in favour of `quinaryLabelColor`, and Xcode 26.4, the
    /// one CI builds with, rejects `quinaryLabelColor` outright as renamed to this. Take the
    /// spelling CI accepts and ignore the beta's deprecation hint.
    internal static var trackEdge: Color { Color(nsColor: .quinaryLabel) }

    /// The system darkens a hovered tab rather than lightening it, in light appearance: a rendered
    /// `NSTabBar` measures rgb(220) under the pointer against a rgb(232) track, and this resolves
    /// to rgb(210) against rgb(220). The direction is deliberate and matches, so it is left alone.
    internal static var hoverFill: Color { Color(nsColor: .tertiarySystemFill) }

    internal static var separator: Color { Color(nsColor: .separatorColor) }

    /// The rim is the other half of how the system draws a raised tab, and the half this strip was
    /// missing. A vertical section through a selected segment reads track 236, rim 215, highlight
    /// 255, body 242: the fill carries six levels and the edge carries twenty-one. Only the fill
    /// was drawn here before, which is why the selection read as flat.
    internal static var selectionEdge: Color { Color(nsColor: .separatorColor) }
}

/// Which of the two surface sets the strip draws.
///
/// The app resolves this from the environment. A test pins it, because a `glassEffect` cannot be
/// rasterised at all: `cacheDisplay` comes back with an empty bitmap for the entire hosting view,
/// the strip's own titles and close button included, not merely for the glass.
internal enum EditorTabStripSurfaceStyle {
    case glass
    case solid
}

/// Whether the strip may use Liquid Glass at all.
///
/// Only the new-tab button asks any more. The track and the selected tab are opaque, because a
/// selection drawn in glass cannot hold its own sign: measured across twenty
/// arrangements on macOS 27, every glass surface nested in, beside, or unioned with another one
/// rendered *darker* than its track in light appearance, and the shipped pair inverted again when
/// the window lost key. Glass takes its colour from whatever is behind the window, and a selection
/// has to mean the same thing over every wallpaper.
///
/// The rule itself belongs to `SolidSurfacePreference`, which the six views that reach both
/// settings through `themeMaterial` also use.
internal enum EditorTabStripEmphasis {
    internal static func prefersSolidSurfaces(
        reduceTransparency: Bool,
        contrast: ColorSchemeContrast
    ) -> Bool {
        SolidSurfacePreference.prefersSolid(reduceTransparency: reduceTransparency, contrast: contrast)
    }
}
