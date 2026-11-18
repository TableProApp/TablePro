//
//  EditorTabStripSurfacesTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct EditorTabStripSurfacesTests {
    nonisolated private static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    // Window colors a theme draws behind the strip: Solarized Light, GitHub Light, plain white and Dracula.
    nonisolated private static let themedBackdrops: [(NSAppearance.Name, String)] = [
        (.aqua, "#FDF6E3"),
        (.aqua, "#F6F8FA"),
        (.aqua, "#FFFFFF"),
        (.darkAqua, "#282A36"),
    ]

    private static let systemTrack = EditorTabStripPalette.trackColor(overThemedBackdrop: false)

    // `relativeLuminance` drops alpha, so a translucent fill is laid over what it covers before it is measured.
    private func composite(_ source: NSColor, over destination: NSColor) -> NSColor {
        guard let top = source.usingColorSpace(.sRGB),
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

    @Test("The selected fill is never the track's own colour", arguments: EditorTabStripSurfacesTests.appearances)
    func selectedFillIsNotTheTrackFill(appearance: NSAppearance.Name) throws {
        let pair = resolve(appearance) {
            (
                Self.systemTrack.usingColorSpace(.sRGB),
                EditorTabStripPalette.selectedColor.usingColorSpace(.sRGB)
            )
        }
        let track = try #require(pair?.0)
        let selected = try #require(pair?.1)
        #expect(track.redComponent != selected.redComponent || track.alphaComponent != selected.alphaComponent)
    }

    @Test("The selected tab stands clear of the track it sits in", arguments: EditorTabStripSurfacesTests.appearances)
    func selectionStandsClearOfTheTrack(appearance: NSAppearance.Name) throws {
        let measured = resolve(appearance) { () -> CGFloat in
            let track = self.composite(Self.systemTrack, over: .windowBackgroundColor)
            let selected = self.composite(EditorTabStripPalette.selectedColor, over: track)
            return self.contrast(selected, track)
        }
        #expect(try #require(measured) > 1.25)
    }

    @Test("The selected fill can never resolve at or below the track", arguments: EditorTabStripSurfacesTests.appearances)
    func selectionNeverInverts(appearance: NSAppearance.Name) throws {
        let measured = resolve(appearance) { () -> (CGFloat, CGFloat) in
            let track = self.composite(Self.systemTrack, over: .windowBackgroundColor)
            let selected = self.composite(EditorTabStripPalette.selectedColor, over: track)
            return (track.relativeLuminance, selected.relativeLuminance)
        }
        let values = try #require(measured)
        #expect(values.1 > values.0)
    }

    @Test(
        "A hovered tab never moves further from the track than the selected one",
        arguments: EditorTabStripSurfacesTests.appearances
    )
    func hoverNeverOutreadsTheSelection(appearance: NSAppearance.Name) throws {
        let measured = resolve(appearance) { () -> (CGFloat, CGFloat) in
            let track = self.composite(Self.systemTrack, over: .windowBackgroundColor)
            let hovered = self.composite(EditorTabStripPalette.hoverColor, over: track)
            let selected = self.composite(EditorTabStripPalette.selectedColor, over: track)
            return (
                abs(hovered.relativeLuminance - track.relativeLuminance),
                abs(selected.relativeLuminance - track.relativeLuminance)
            )
        }
        let values = try #require(measured)
        #expect(values.0 < values.1)
    }

    @Test("The tab is inset inside the track on every side")
    func tabIsInsetInsideTheTrack() {
        #expect(
            EditorTabStripLayout.tabHeight
                == EditorTabStripLayout.trackHeight - EditorTabStripLayout.trackPadding * 2
        )
        #expect(EditorTabStripLayout.trackHeight < EditorTabStripLayout.bandHeight)
    }

    @Test(
        "Over a themed window the selected tab keeps a step above the track",
        arguments: EditorTabStripSurfacesTests.themedBackdrops
    )
    func selectionStandsClearOverAThemedWindow(appearance: NSAppearance.Name, windowHex: String) throws {
        let measured = resolve(appearance) { () -> (CGFloat, CGFloat, CGFloat) in
            let track = self.composite(
                EditorTabStripPalette.trackColor(overThemedBackdrop: true),
                over: HexColor.color(windowHex)
            )
            let selected = self.composite(EditorTabStripPalette.selectedColor, over: track)
            return (self.contrast(selected, track), track.relativeLuminance, selected.relativeLuminance)
        }
        let values = try #require(measured)
        #expect(values.0 > 1.16, "step \(values.0) over \(windowHex)")
        #expect(values.2 > values.1)
    }
}
