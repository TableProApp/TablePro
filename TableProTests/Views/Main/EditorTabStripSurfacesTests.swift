//
//  EditorTabStripSurfacesTests.swift
//  TableProTests
//
//  The strip's track and selected tab are opaque fills, so what these pin is the one
//  property the selection rests on: that it can never resolve at or below the track, in any
//  appearance. It used to be a pair of Liquid Glass tints, whose step was a function of the
//  wallpaper behind the window and inverted outright on macOS 27 (#2439).
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@Suite("Editor tab strip surfaces")
@MainActor
struct EditorTabStripSurfacesTests {
    /// The two appearances that can actually be instantiated, and no more.
    ///
    /// This list used to carry `.accessibilityHighContrastAqua` and its dark twin as well, which
    /// covered nothing: those constants carry the raw values "NSAppearanceNameAccessibilityAqua"
    /// and "NSAppearanceNameAccessibilityDarkAqua", and `NSAppearance(named:)` resolves both back
    /// to plain Aqua and DarkAqua, which `NSAppearance.currentDrawing().name` confirms from inside
    /// the block. So the suite ran the same two appearances twice and reported four.
    ///
    /// Spelling the real names out does not rescue it either: "NSAppearanceNameAccessibilityHigh-
    /// ContrastAqua" instantiates in a plain process and returns nil in the test host, so the
    /// cases fail rather than cover anything. Increase Contrast is a system setting, not an
    /// appearance to borrow, which is why the app reads it through `colorSchemeContrast` and why
    /// `solidSurfacesAnswerBothSettings` below is where that contract is pinned.
    nonisolated private static let appearances: [NSAppearance.Name] = [
        .aqua,
        .darkAqua,
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

    // MARK: - The selection can never invert

    /// The defect behind #2439, expressed as the property that prevents it. In light appearance
    /// `controlColor` is opaque white, so it is the ceiling and no track can rise above it; in
    /// dark it is white at alpha 0.247, so it composites *over* whatever the track resolved to and
    /// always lifts. Either way the selected tab is lighter than its track, by construction rather
    /// than by a tuned distance. The Liquid Glass tints it replaced had neither guarantee.
    @Test(
        "The selected fill can never resolve at or below the track",
        arguments: EditorTabStripSurfacesTests.appearances
    )
    func selectionNeverInverts(appearance: NSAppearance.Name) {
        let measured = resolve(appearance) { () -> (CGFloat, CGFloat) in
            let track = self.composite(EditorTabStripPalette.trackFill, over: .windowBackgroundColor)
            let selected = self.composite(EditorTabStripPalette.selectedFill, over: track)
            return (track.relativeLuminance, selected.relativeLuminance)
        }
        guard let measured else {
            Issue.record("The strip's fills did not resolve")
            return
        }
        #expect(measured.1 > measured.0)
    }

    /// A hovered tab has to stay a hint. The system darkens one in light appearance rather than
    /// lightening it, so hover and selection travel in opposite directions and the only thing
    /// worth pinning is that hover never travels further.
    @Test(
        "A hovered tab never moves further from the track than the selected one",
        arguments: EditorTabStripSurfacesTests.appearances
    )
    func hoverNeverOutreadsTheSelection(appearance: NSAppearance.Name) {
        let measured = resolve(appearance) { () -> (CGFloat, CGFloat) in
            let track = self.composite(EditorTabStripPalette.trackFill, over: .windowBackgroundColor)
            let hovered = self.composite(EditorTabStripPalette.hoverFill, over: track)
            let selected = self.composite(EditorTabStripPalette.selectedFill, over: track)
            return (
                abs(hovered.relativeLuminance - track.relativeLuminance),
                abs(selected.relativeLuminance - track.relativeLuminance)
            )
        }
        guard let measured else {
            Issue.record("The strip's fills did not resolve")
            return
        }
        #expect(measured.0 < measured.1)
    }

    /// The tab is inset inside the track by the padding on every side, so the two capsules stay
    /// concentric at their ends and the selected one never overruns the track's curve. Both are
    /// fully rounded, which is what the system's own tab bar draws: its runtime view tree reports
    /// `cornerRadius = 12` on each 24pt tab, exactly half the height.
    @Test("The tab is inset inside the track on every side")
    func tabIsInsetInsideTheTrack() {
        #expect(
            EditorTabStripLayout.tabHeight
                == EditorTabStripLayout.trackHeight - EditorTabStripLayout.trackPadding * 2
        )
        #expect(EditorTabStripLayout.trackHeight < EditorTabStripLayout.bandHeight)
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
