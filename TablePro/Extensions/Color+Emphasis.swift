//
//  Color+Emphasis.swift
//  TablePro
//

import AppKit
import SwiftUI

internal extension Color {
    /// The foreground AppKit pairs with an emphasized selection fill. Hardcoding white instead
    /// breaks the moment the user picks a light accent colour or turns on Increase Contrast,
    /// because the fill follows both settings and a literal colour does not.
    static let emphasizedSelectionLabel = Color(nsColor: .alternateSelectedControlTextColor)

    /// White is legible only on a dark fill. A user-picked tag colour, or a semantic colour such
    /// as orange, can be light enough that white text disappears into it, so the label is derived
    /// from the fill rather than assumed.
    static func legibleForeground(on fill: Color) -> Color {
        NSColor(fill).relativeLuminance > Self.darkLabelThreshold ? .black : .white
    }

    /// Above this luminance a fill takes a dark label. The equal-contrast crossover is 0.179, but
    /// that puts black on system blue and system red, which no Mac control does. This sits high
    /// enough to keep white on the saturated hues and still flips on yellow, mint, teal and
    /// orange, where white genuinely disappears. Every palette colour is held to 3:1 by test.
    private static let darkLabelThreshold: CGFloat = 0.3
}

internal extension NSColor {
    var relativeLuminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * Self.linearized(rgb.redComponent)
            + 0.7152 * Self.linearized(rgb.greenComponent)
            + 0.0722 * Self.linearized(rgb.blueComponent)
    }

    private static func linearized(_ channel: CGFloat) -> CGFloat {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}
