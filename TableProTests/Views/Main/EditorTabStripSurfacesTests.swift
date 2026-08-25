//
//  EditorTabStripSurfacesTests.swift
//  TableProTests
//
//  The tab strip's selected surface cannot be rasterised on macOS 26 and later, because glass is
//  composited by the window server rather than drawn into a view's context. What can be pinned is
//  the arithmetic underneath it: that the track and the selection are pulled in opposite
//  directions, and that the opaque surfaces the strip falls back to are two colours rather than
//  one. They were one, and a background window on macOS 14 and 15 showed no selected tab at all.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@Suite("Editor tab strip surfaces")
@MainActor
struct EditorTabStripSurfacesTests {
    nonisolated private static let appearances: [NSAppearance.Name] = [
        .aqua,
        .darkAqua,
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
    ]

    /// `NSColor.relativeLuminance` drops the alpha component, so a translucent fill has to be laid
    /// over what it covers before it can be measured at all. `controlColor` is white at a quarter
    /// alpha in dark, which reads as pure white until it is composited.
    private func composite(_ source: Color, over destination: NSColor) -> NSColor {
        guard let top = NSColor(source).usingColorSpace(.sRGB),
              let bottom = destination.usingColorSpace(.sRGB)
        else { return destination }
        let alpha = top.alphaComponent
        return NSColor(
            srgbRed: top.redComponent * alpha + bottom.redComponent * (1 - alpha),
            green: top.greenComponent * alpha + bottom.greenComponent * (1 - alpha),
            blue: top.blueComponent * alpha + bottom.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private func contrast(_ one: NSColor, _ other: NSColor) -> CGFloat {
        let first = one.relativeLuminance
        let second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func resolve<T>(_ appearance: NSAppearance.Name, _ body: () -> T) -> T? {
        var result: T?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { result = body() }
        return result
    }

    // MARK: - The opaque surfaces

    /// The bug this suite exists for. `selectedFill` used to be the track's own
    /// `unemphasizedSelectedContentBackgroundColor` whenever the window was not in front, and both
    /// resolve opaque, so the selected capsule and the track it sat in were the same pixel.
    @Test(
        "The opaque selected fill is never the track's own colour",
        arguments: EditorTabStripSurfacesTests.appearances
    )
    func selectedFillIsNotTheTrackFill(appearance: NSAppearance.Name) {
        let pair = resolve(appearance) {
            (
                NSColor(EditorTabStripPalette.trackFill).usingColorSpace(.sRGB),
                NSColor(EditorTabStripPalette.selectedFill).usingColorSpace(.sRGB)
            )
        }
        guard let track = pair?.0, let selected = pair?.1 else {
            Issue.record("The strip's opaque fills did not resolve")
            return
        }
        /// Compared on resolved components rather than with `==`, which answers how a colour was
        /// built rather than what it draws.
        #expect(
            track.redComponent != selected.redComponent
                || track.alphaComponent != selected.alphaComponent
        )
    }

    @Test(
        "The opaque selected tab stands clear of the track it sits in",
        arguments: EditorTabStripSurfacesTests.appearances
    )
    func opaqueSelectionStandsClearOfTheTrack(appearance: NSAppearance.Name) {
        let measured = resolve(appearance) { () -> CGFloat in
            let track = self.composite(EditorTabStripPalette.trackFill, over: .windowBackgroundColor)
            let selected = self.composite(EditorTabStripPalette.selectedFill, over: track)
            return self.contrast(selected, track)
        }
        guard let measured else {
            Issue.record("The strip's opaque fills did not resolve")
            return
        }
        /// The system's own tab bar measures 1.161 to 1 in light and 1.098 to 1 in dark. The opaque
        /// path carries far more than that, 1.371 and 1.991, because it is what the strip falls
        /// back to when the user has asked for Increase Contrast or Reduce Transparency.
        #expect(measured > 1.25)
    }

    // MARK: - The glass tints

    /// Neither tint means anything on its own. What holds the selection apart from its track is
    /// that they are pushed in opposite directions from the same backdrop, which is the one thing
    /// two `.regular` surfaces cannot do.
    @Test("The track and the selection are tinted away from each other")
    func tintsPullInOppositeDirections() {
        let backdrop = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let subdued = composite(EditorTabStripEmphasis.trackTint, over: backdrop)
        let lifted = composite(EditorTabStripEmphasis.selectionTint, over: backdrop)

        #expect(subdued.relativeLuminance < backdrop.relativeLuminance)
        #expect(lifted.relativeLuminance > backdrop.relativeLuminance)
        #expect(lifted.relativeLuminance > subdued.relativeLuminance)
    }

    /// `Glass.regular` discards hue and reads only lightness, so a tint that carries a colour
    /// measures the same as no tint at all and the selection goes back to being whatever the
    /// backdrop makes it.
    @Test("Both tints are neutral")
    func tintsCarryNoHue() {
        for tint in [EditorTabStripEmphasis.trackTint, EditorTabStripEmphasis.selectionTint] {
            guard let resolved = NSColor(tint).usingColorSpace(.sRGB) else {
                Issue.record("A tab strip tint did not resolve")
                return
            }
            #expect(resolved.redComponent == resolved.greenComponent)
            #expect(resolved.greenComponent == resolved.blueComponent)
            #expect(resolved.alphaComponent > 0)
            #expect(resolved.alphaComponent < 1)
        }
    }

    // MARK: - Leaving glass behind

    @Test("Either accessibility setting alone takes the strip off glass")
    func solidSurfacesAnswerBothSettings() {
        #expect(!EditorTabStripEmphasis.prefersSolidSurfaces(reduceTransparency: false, contrast: .standard))
        #expect(EditorTabStripEmphasis.prefersSolidSurfaces(reduceTransparency: true, contrast: .standard))
        #expect(EditorTabStripEmphasis.prefersSolidSurfaces(reduceTransparency: false, contrast: .increased))
        #expect(EditorTabStripEmphasis.prefersSolidSurfaces(reduceTransparency: true, contrast: .increased))
    }
}
