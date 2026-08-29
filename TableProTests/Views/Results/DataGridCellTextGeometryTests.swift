//
//  DataGridCellTextGeometryTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

/// The drawn cell and the overlay editor read their geometry from one owner, and these tests
/// are what keeps a second owner from growing back. The baseline test measures the overlay's
/// real TextKit 2 layout through `textLayoutManager`, never `layoutManager`: reading that
/// property downgrades the view to TextKit 1 and would validate an engine production never
/// runs (#2381).
@Suite("Data grid cell text geometry")
@MainActor
struct DataGridCellTextGeometryTests {
    private static let rowHeights: [CGFloat] = [20, 24, 28, 32]
    private static let fonts: [NSFont] = [
        .monospacedSystemFont(ofSize: 12, weight: .regular),
        .systemFont(ofSize: 13),
        .monospacedSystemFont(ofSize: 18, weight: .regular),
    ]

    @Test("The shared baseline is the centered formula, floored to a whole point")
    func baselineIsFlooredCenter() {
        for font in Self.fonts {
            for rowHeight in Self.rowHeights {
                let fractional = (rowHeight - font.ascender + font.descender - font.leading) / 2
                    + font.ascender
                let shared = DataGridCellTextGeometry.baselineY(rowHeight: rowHeight, font: font)
                #expect(shared == fractional.rounded(.down))
                #expect(shared == shared.rounded(.down))
            }
        }
    }

    @Test("A single-line value gets exactly the cell it is editing, at every row height")
    func singleLineOverlayIsTheCell() {
        for rowHeight in Self.rowHeights {
            let cellFrame = NSRect(x: 117, y: 66, width: 140, height: rowHeight)
            #expect(CellOverlayBase.overlayFrame(for: cellFrame, value: "completed") == cellFrame)
            #expect(CellOverlayBase.overlayFrame(for: cellFrame, value: "") == cellFrame)
        }
    }

    @Test("The overlay text view puts its first baseline on the drawn baseline")
    func overlayBaselineMatchesTheDrawnBaseline() throws {
        for font in Self.fonts {
            for rowHeight in Self.rowHeights {
                let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 140, height: rowHeight))
                CellOverlayBase.applyCellTextLayout(to: textView)
                CellOverlayBase.configureCellTextGeometry(of: textView, rowHeight: rowHeight, font: font)
                textView.font = font
                textView.string = "completed"

                let layoutManager = try #require(
                    textView.textLayoutManager, "the overlay has to stay on TextKit 2"
                )
                layoutManager.ensureLayout(for: layoutManager.documentRange)
                let fragment = try #require(
                    layoutManager.textLayoutFragment(for: layoutManager.documentRange.location)
                )
                let line = try #require(fragment.textLineFragments.first)

                let renderedBaseline = textView.textContainerInset.height
                    + fragment.layoutFragmentFrame.minY
                    + line.glyphOrigin.y
                let drawnBaseline = DataGridCellTextGeometry.baselineY(rowHeight: rowHeight, font: font)
                #expect(
                    abs(renderedBaseline - drawnBaseline) < 0.001,
                    "\(font.fontName) \(font.pointSize)pt in a \(rowHeight)pt row: rendered \(renderedBaseline), drawn \(drawnBaseline)"
                )
            }
        }
    }

    @Test("The overlay glyphs start at the drawn cell's horizontal inset")
    func overlayHorizontalInsetMatchesTheRenderer() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 140, height: 28))
        CellOverlayBase.applyCellTextLayout(to: textView)
        CellOverlayBase.configureCellTextGeometry(
            of: textView, rowHeight: 28, font: .systemFont(ofSize: 13)
        )
        let container = try #require(textView.textContainer)
        #expect(container.lineFragmentPadding == DataGridMetrics.cellHorizontalInset)
        #expect(textView.textContainerInset.width == 0)
    }

    /// The expectation is rebuilt from a raw `NSLayoutManager` and the written-out formula,
    /// never from `DataGridCellTextGeometry`, so a drift in the shared geometry fails here
    /// instead of being copied into the expectation.
    @Test("A multiline value grows by the geometry the text view is configured with")
    func multilineHeightComesFromTheSharedGeometry() {
        let cellFrame = NSRect(x: 0, y: 0, width: 140, height: 32)
        let font = ThemeEngine.shared.valueFont
        let measurer = NSLayoutManager()
        let flooredBaseline = ((32 - font.ascender + font.descender - font.leading) / 2
            + font.ascender).rounded(.down)
        let inset = flooredBaseline - measurer.defaultBaselineOffset(for: font)
        let expected = min(max(2 * measurer.defaultLineHeight(for: font) + 2 * inset, 32), 120)

        let twoLines = CellOverlayBase.overlayFrame(for: cellFrame, value: "a\nb")
        #expect(twoLines.height == expected)
        #expect(twoLines.height > cellFrame.height)
        #expect(twoLines.origin == cellFrame.origin)
        #expect(twoLines.width == cellFrame.width)

        let manyLines = CellOverlayBase.overlayFrame(
            for: cellFrame, value: Array(repeating: "x", count: 200).joined(separator: "\n")
        )
        #expect(manyLines.height == CellOverlayBase.maximumOverlayHeight)
    }

    /// TextKit starts a new line fragment on LF, lone CR, NEL and the Unicode line and
    /// paragraph separators, and treats CRLF as one break. Counting only LF classified a
    /// "line1\rline2" value as single-line and hid its second line behind a one-row overlay.
    @Test("Line breaks are counted the way TextKit lays them out")
    func lineBreaksCountLikeTextKit() {
        #expect(CellOverlayBase.lineBreakCount(in: "one line") == 0)
        #expect(CellOverlayBase.lineBreakCount(in: "") == 0)
        #expect(CellOverlayBase.lineBreakCount(in: "a\nb") == 1)
        #expect(CellOverlayBase.lineBreakCount(in: "a\rb") == 1)
        #expect(CellOverlayBase.lineBreakCount(in: "a\r\nb") == 1)
        #expect(CellOverlayBase.lineBreakCount(in: "a\u{85}b") == 1)
        #expect(CellOverlayBase.lineBreakCount(in: "a\u{2028}b") == 1)
        #expect(CellOverlayBase.lineBreakCount(in: "a\u{2029}b") == 1)
        #expect(CellOverlayBase.lineBreakCount(in: "a\r\n\r\nb") == 2)
        #expect(CellOverlayBase.lineBreakCount(in: "a\r\rb") == 2)

        let cellFrame = NSRect(x: 0, y: 0, width: 140, height: 28)
        #expect(CellOverlayBase.overlayFrame(for: cellFrame, value: "line1\rline2") != cellFrame)
        #expect(CellOverlayBase.overlayFrame(for: cellFrame, value: "a\u{2028}b") != cellFrame)
    }

    /// The overlay frames itself from `frameOfCell` while the renderer draws into
    /// `rect(ofColumn:)`; this pins the measured fact that their x origins agree on every
    /// column a user can edit (attached index 0 is the row-number column, never editable).
    @Test("frameOfCell and rect(ofColumn:) agree on x for editable columns")
    func overlayRectSourceMatchesTheRendererRectSource() {
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowHeight = 28
        for i in 0..<3 {
            let column = NSTableColumn(identifier: .init("c\(i)"))
            column.width = 100
            tableView.addTableColumn(column)
        }
        let dataSource = FixedRowCountDataSource()
        tableView.dataSource = dataSource
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()

        for column in 1..<3 {
            let cellFrame = tableView.frameOfCell(atColumn: column, row: 1)
            let columnRect = tableView.rect(ofColumn: column)
            #expect(cellFrame.minX == columnRect.minX)
            #expect(cellFrame.height == tableView.rect(ofRow: 1).height)
        }
    }
}

private final class FixedRowCountDataSource: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 5 }
}
