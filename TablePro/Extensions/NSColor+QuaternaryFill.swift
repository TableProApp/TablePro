//
//  NSColor+QuaternaryFill.swift
//  TablePro
//

import AppKit

internal extension NSColor {
    /// `quaternarySystemFill` is macOS 14. The fallback tracks the label colour rather than
    /// naming a fixed grey, so it follows the appearance and the accessibility contrast
    /// setting the way the system fill does.
    static var quaternaryFill: NSColor {
        if #available(macOS 14.0, *) {
            return .quaternarySystemFill
        }
        return .labelColor.withAlphaComponent(0.05)
    }

    /// `tertiarySystemFill` is macOS 14. Same shape as `quaternaryFill`: the fallback tracks
    /// the label colour so it follows appearance and contrast settings.
    static var tertiaryFill: NSColor {
        if #available(macOS 14.0, *) {
            return .tertiarySystemFill
        }
        return .labelColor.withAlphaComponent(0.08)
    }
}
