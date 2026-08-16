//
//  HistoryRowTintTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@Suite("History row tints on a selection fill")
@MainActor
struct HistoryRowTintTests {
    private func entry(wasSuccessful: Bool) -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: "SELECT 1",
            connectionId: UUID(),
            databaseName: "db",
            databaseType: .postgresql,
            source: .editor,
            executedAt: Date(timeIntervalSince1970: 0),
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: wasSuccessful
        )
    }

    /// Renders the row over the same fill AppKit paints for an emphasized selection, and counts the
    /// pixels that are still the raw tint rather than the selected-content colour.
    private func offTintPixels(
        wasSuccessful: Bool,
        connectionLabel: HistoryConnectionLabel?,
        prominence: BackgroundProminence,
        matches: (NSColor) -> Bool
    ) -> Int {
        let row = HistoryRowView(entry: entry(wasSuccessful: wasSuccessful), connectionLabel: connectionLabel)
            .frame(width: 320, height: 44)
            .background(Color(nsColor: .selectedContentBackgroundColor))
            .environment(\.backgroundProminence, prominence)

        let renderer = ImageRenderer(content: row)
        renderer.scale = 1
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

    private func isRed(_ color: NSColor) -> Bool {
        color.redComponent > 0.6 && color.greenComponent < 0.45 && color.blueComponent < 0.45
    }

    private func isGreenish(_ color: NSColor) -> Bool {
        color.greenComponent > 0.45 && color.greenComponent - color.blueComponent > 0.2
    }

    /// The regression. A failed entry drew a fixed red glyph, which SwiftUI does not remap, so it
    /// sat on the accent fill at roughly 1.5:1 and read as a dark blob.
    @Test("The failure glyph leaves the accent fill when the row is emphasized")
    func failureGlyphAdaptsToProminence() {
        let standard = offTintPixels(
            wasSuccessful: false, connectionLabel: nil, prominence: .standard, matches: isRed
        )
        let increased = offTintPixels(
            wasSuccessful: false, connectionLabel: nil, prominence: .increased, matches: isRed
        )

        #expect(standard > 0)
        #expect(increased == 0)
    }

    @Test("A successful entry never draws red at either prominence")
    func successGlyphIsNeverRed() {
        #expect(offTintPixels(wasSuccessful: true, connectionLabel: nil, prominence: .standard, matches: isRed) == 0)
        #expect(offTintPixels(wasSuccessful: true, connectionLabel: nil, prominence: .increased, matches: isRed) == 0)
    }

    /// A connection colour is a stored value, so it stayed itself on the fill. Green is the clearest
    /// of the palette to count against an accent-blue background.
    @Test("The connection dot leaves the accent fill when the row is emphasized")
    func connectionDotAdaptsToProminence() {
        let label = HistoryConnectionLabel(name: "Chinook", color: .green)

        let standard = offTintPixels(
            wasSuccessful: true, connectionLabel: label, prominence: .standard, matches: isGreenish
        )
        let increased = offTintPixels(
            wasSuccessful: true, connectionLabel: label, prominence: .increased, matches: isGreenish
        )

        #expect(standard > 0)
        #expect(increased == 0)
    }
}
