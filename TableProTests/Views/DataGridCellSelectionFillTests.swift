//
//  DataGridCellSelectionFillTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// The cell-range wash has to stay visible when the grid loses focus. Thinning the unemphasized
/// selection colour out to 28% put it at 1.09:1 against a white grid, which reads as no selection
/// at all, so the colour is now used at the opacity AppKit uses it at.
@Suite("Data grid cell selection fill")
@MainActor
struct DataGridCellSelectionFillTests {
    /// The fill is built inside the appearance block. A dynamic colour resolves against whatever
    /// appearance is current when it is read, so building it outside would mix one appearance's
    /// fill with the other's background.
    private func contrast(
        in name: NSAppearance.Name,
        fill makeFill: () -> NSColor
    ) -> CGFloat {
        var ratio: CGFloat = 0
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            let background = NSColor.controlBackgroundColor
            let foreground = Self.composite(makeFill(), over: background).relativeLuminance
            let backgroundLuminance = background.relativeLuminance
            ratio = (max(foreground, backgroundLuminance) + 0.05) / (min(foreground, backgroundLuminance) + 0.05)
        }
        return ratio
    }

    private static func composite(_ fill: NSColor, over background: NSColor) -> NSColor {
        guard let source = fill.usingColorSpace(.sRGB),
              let destination = background.usingColorSpace(.sRGB) else { return fill }
        let alpha = source.alphaComponent
        return NSColor(
            srgbRed: source.redComponent * alpha + destination.redComponent * (1 - alpha),
            green: source.greenComponent * alpha + destination.greenComponent * (1 - alpha),
            blue: source.blueComponent * alpha + destination.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    @Test("The unemphasized selection colour is opaque, the way AppKit fills it")
    func unemphasizedFillIsOpaque() {
        #expect(NSColor.unemphasizedSelectedContentBackgroundColor.alphaComponent == 1)
    }

    @Test("An unfocused cell range stays visible in every appearance")
    func unfocusedRangeStaysVisible() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let ratio = contrast(in: name) { .unemphasizedSelectedContentBackgroundColor }
            #expect(ratio > 1.3, "unfocused cell range is invisible in \(name.rawValue) at \(ratio)")
        }
    }

    /// The old shape thinned the same colour to 28%, which is what made it disappear. Keeping the
    /// measurement here means a change back to a wash fails instead of shipping.
    @Test("Thinning the unemphasized colour is what made it invisible")
    func thinnedFillIsInvisible() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let ratio = contrast(in: name) {
                NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.28)
            }
            #expect(ratio < 1.2, "thinned fill unexpectedly visible in \(name.rawValue) at \(ratio)")
        }
    }

    @Test("The emphasized accent stays a tint so cell text under it survives")
    func emphasizedFillStaysATint() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let ratio = contrast(in: name) {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28)
            }
            #expect(ratio > 1.2, "emphasized cell range is invisible in \(name.rawValue) at \(ratio)")
        }
    }
}
