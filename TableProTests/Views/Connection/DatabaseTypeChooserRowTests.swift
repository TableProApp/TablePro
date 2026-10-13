//
//  DatabaseTypeChooserRowTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct DatabaseTypeChooserRowTests {
    @available(macOS 14.0, *)
    private func pixels(
        of type: DatabaseType,
        isCurrent: Bool,
        prominence: BackgroundProminence,
        matching matches: (NSColor) -> Bool
    ) -> Int {
        // A fixed fill: the selection colour follows the user's accent, and a red accent reads as the glyph.
        let row = DatabaseTypeChooserRow(type: type, isCurrent: isCurrent)
            .frame(width: 360, height: 44)
            .background(Color.blue)
            .environment(\.backgroundProminence, prominence)

        let renderer = ImageRenderer(content: row)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            Issue.record("The row did not render")
            return -1
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if matches(color) { count += 1 }
            }
        }
        return count
    }

    private static func isRed(_ color: NSColor) -> Bool {
        color.redComponent > 0.6 && color.greenComponent < 0.45 && color.blueComponent < 0.45
    }

    private static func isWhite(_ color: NSColor) -> Bool {
        color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9
    }

    @available(macOS 14.0, *)
    @Test("The brand glyph leaves its colour for the selected-content colour on an emphasized row")
    func brandGlyphFollowsSelection() {
        #expect(pixels(of: .redis, isCurrent: false, prominence: .standard, matching: Self.isRed) > 0)
        #expect(pixels(of: .redis, isCurrent: false, prominence: .increased, matching: Self.isRed) == 0)
    }

    /// The tint style ignores prominence, so the checkmark stayed accent on the accent fill and vanished.
    @available(macOS 14.0, *)
    @Test("The current-type checkmark turns to the selected-content colour on an emphasized row")
    func checkmarkFollowsSelection() {
        let marked = pixels(of: .postgresql, isCurrent: true, prominence: .increased, matching: Self.isWhite)
        let unmarked = pixels(of: .postgresql, isCurrent: false, prominence: .increased, matching: Self.isWhite)

        #expect(marked - unmarked > 10)
    }
}
