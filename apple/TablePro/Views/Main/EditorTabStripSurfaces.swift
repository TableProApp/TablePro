//
//  EditorTabStripSurfaces.swift
//  TablePro
//

import AppKit

internal enum EditorTabStripPalette {
    internal static var followsWindowBackdrop: Bool {
        ThemeWindowBackdrop.canReachChrome
    }

    @MainActor
    internal static func isOverThemedBackdrop(highContrast: Bool) -> Bool {
        followsWindowBackdrop && ThemeBackdropState.isThemed(highContrast: highContrast)
    }

    // Over a themed window an opaque gray cuts a slab into the theme, so the track takes a translucent system fill.
    internal static func trackColor(overThemedBackdrop: Bool) -> NSColor {
        let native = NSColor.unemphasizedSelectedContentBackgroundColor
        guard overThemedBackdrop else { return native }
        if #available(macOS 14.0, *) { return .secondarySystemFill }
        return native
    }

    // Opaque white in light and translucent white in dark, so the selection always sits above the track.
    internal static var selectedColor: NSColor { .controlColor }

    // `quinaryLabel`, not `quinaryLabelColor`: Xcode 26.4 on CI rejects the newer spelling.
    internal static var trackEdgeColor: NSColor { .quinaryLabel }

    internal static var hoverColor: NSColor { .tertiaryFill }

    internal static var separatorColor: NSColor { .separatorColor }

    internal static var selectionEdgeColor: NSColor { .separatorColor }
}
