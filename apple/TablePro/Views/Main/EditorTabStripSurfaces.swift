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

    // A vibrant strip sits on the material of an opaque titlebar, which the window color never reaches.
    @MainActor
    internal static func isOverThemedBackdrop(in appearance: NSAppearance, highContrast: Bool) -> Bool {
        !appearance.allowsVibrancy && isOverThemedBackdrop(highContrast: highContrast)
    }

    // An opaque titlebar, as in full screen, makes the strip vibrant, where `controlColor` resolves darker than
    // the track. The fills are picked for the transparent titlebar, so a vibrant strip resolves them in its
    // window's appearance, which also carries Increase Contrast.
    @MainActor
    internal static func drawing(_ view: NSView, _ body: () -> Void) {
        guard view.effectiveAppearance.allowsVibrancy, let window = view.window else {
            body()
            return
        }
        window.effectiveAppearance.performAsCurrentDrawingAppearance(body)
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
