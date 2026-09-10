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
    static let darkLabelThreshold: CGFloat = 0.3

    /// What WCAG 2.2 asks of text below 18pt, or below 14pt bold. Every font the toolbar and the
    /// welcome list put on a fill is smaller than both, so a fill carrying a label is held here
    /// rather than at the 3:1 that covers an icon or a border.
    static let minimumLabelContrast: CGFloat = 4.5
}

internal extension NSColor {
    var relativeLuminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * Self.linearized(rgb.redComponent)
            + 0.7152 * Self.linearized(rgb.greenComponent)
            + 0.0722 * Self.linearized(rgb.blueComponent)
    }

    /// The contrast this fill would reach against the label `Color.legibleForeground(on:)` picks
    /// for it.
    var contrastWithDerivedLabel: CGFloat {
        let fill = relativeLuminance
        let label: CGFloat = fill > Color.darkLabelThreshold ? 0 : 1
        return (max(label, fill) + 0.05) / (min(label, fill) + 0.05)
    }

    /// The same hue, dimmed only as far as its derived label needs to clear `minimumRatio`.
    ///
    /// `legibleForeground(on:)` picks black or white from luminance alone, and that is enough for
    /// an icon or a border at 3:1 but not for a label at 4.5:1: measured against the connection
    /// palette, red, blue, purple, pink and grey leave their label between 3.2:1 and 4.2:1, while
    /// orange, yellow and green already clear it with a black label and are returned untouched.
    /// Lowering brightness in HSB holds hue and saturation, so the fill still reads as the colour
    /// the user picked; the worst case keeps 83% of its brightness.
    func tunedForLegibleLabel(minimumRatio: CGFloat = Color.minimumLabelContrast) -> NSColor {
        guard let srgb = usingColorSpace(.sRGB) else { return self }
        guard srgb.contrastWithDerivedLabel < minimumRatio else { return self }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        var tooDim: CGFloat = 0
        var tooBright = brightness
        var tuned: NSColor?
        for _ in 0 ..< Self.labelTuningSteps {
            let candidate = NSColor(hue: hue, saturation: saturation, brightness: (tooDim + tooBright) / 2, alpha: alpha)
            if candidate.contrastWithDerivedLabel >= minimumRatio {
                tuned = candidate
                tooDim = (tooDim + tooBright) / 2
            } else {
                tooBright = (tooDim + tooBright) / 2
            }
        }
        /// At the ratios this app asks for, the first candidate always passes and the search only
        /// refines it. A caller naming a ratio no brightness of this hue can reach would otherwise
        /// be handed pure black, silently losing the hue, so an unreachable target keeps the colour
        /// it was given and leaves the contrast decision with the caller.
        return tuned ?? self
    }

    /// Enough halvings of the brightness range to land inside a step no 8-bit channel can express.
    private static let labelTuningSteps = 12

    private static func linearized(_ channel: CGFloat) -> CGFloat {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}
