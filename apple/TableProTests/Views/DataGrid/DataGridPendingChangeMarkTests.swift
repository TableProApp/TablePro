//
//  DataGridPendingChangeMarkTests.swift
//  TableProTests
//

import AppKit
import CoreText
@testable import TablePro
import Testing

@MainActor
struct DataGridPendingChangeMarkTests {
    private let palette = DataGridCellPalette(
        regularFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        italicFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        mediumFont: .monospacedSystemFont(ofSize: 13, weight: .medium),
        text: .labelColor,
        placeholderText: .secondaryLabelColor,
        booleanTrueText: .labelColor,
        booleanFalseText: .labelColor,
        rowNumberText: .secondaryLabelColor,
        deletedRowText: .systemRed,
        modifiedColumnTint: .systemYellow,
        findMatchTint: .systemOrange
    )

    private static let deleted = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [])
    private static let inserted = RowVisualState(isDeleted: false, isInserted: true, modifiedColumns: [])
    private static let modified = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [1])

    private func resolve(
        text: String = "value",
        visualState: RowVisualState = .empty,
        columnIndex: Int = 0,
        isCurrentFindMatch: Bool = false,
        onEmphasizedSelection: Bool = false
    ) -> DataGridCellAppearance {
        DataGridCellAppearance.resolve(
            kind: .text,
            content: DataGridCellContent(displayText: text, rawValue: text, placeholder: nil),
            state: DataGridCellState(
                visualState: visualState,
                isEditable: true,
                isCurrentFindMatch: isCurrentFindMatch,
                row: 0,
                columnIndex: columnIndex
            ),
            palette: palette,
            nullDisplayString: "NULL",
            onEmphasizedSelection: onEmphasizedSelection
        )
    }

    // MARK: - Which mark a state carries

    @Test("A row staged for deletion is struck through, a new row underlined")
    func rowMarks() {
        #expect(resolve(visualState: Self.deleted).textMark == .struckThrough)
        #expect(resolve(visualState: Self.inserted).textMark == .underlined)
        #expect(resolve().textMark == nil)
    }

    @Test("Only the edited cell of an edited row is underlined")
    func modifiedColumnOnly() {
        #expect(resolve(visualState: Self.modified, columnIndex: 1).textMark == .underlined)
        #expect(resolve(visualState: Self.modified, columnIndex: 0).textMark == nil)
    }

    @Test("A deleted row that was edited first keeps the strike alone")
    func deleteOutranksTheEdit() {
        let state = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [1])

        #expect(resolve(visualState: state, columnIndex: 1).textMark == .struckThrough)
    }

    @Test("The mark survives a selection and a find match, where the tint does not")
    func markSurvivesWhatHidesTheTint() {
        let selected = resolve(visualState: Self.modified, columnIndex: 1, onEmphasizedSelection: true)
        let found = resolve(visualState: Self.modified, columnIndex: 1, isCurrentFindMatch: true)
        let deletedAndSelected = resolve(visualState: Self.deleted, onEmphasizedSelection: true)

        #expect(selected.backgroundTint == nil)
        #expect(selected.textMark == .underlined)
        #expect(found.backgroundTint == palette.findMatchTint)
        #expect(found.textMark == .underlined)
        #expect(deletedAndSelected.textMark == .struckThrough)
    }

    // MARK: - What a client is told

    @Test("A pending change names itself, and distinguishes a new row from an edited value")
    func accessibilityDescriptions() {
        #expect(DataGridCellTextMark.accessibilityDescription(state: Self.deleted, columnIndex: 0) != nil)
        #expect(
            DataGridCellTextMark.accessibilityDescription(state: Self.inserted, columnIndex: 0)
                != DataGridCellTextMark.accessibilityDescription(state: Self.modified, columnIndex: 1)
        )
        #expect(DataGridCellTextMark.accessibilityDescription(state: Self.modified, columnIndex: 0) == nil)
        #expect(DataGridCellTextMark.accessibilityDescription(state: .empty, columnIndex: 0) == nil)
    }

    // MARK: - What is actually drawn

    // Read back over mid grey: a selected cell's text is white and would vanish on white.
    private func inkedColumns(of appearance: DataGridCellAppearance, in rect: NSRect) throws -> [[Int]] {
        let host = CellHost(frame: rect)
        host.cellAppearance = appearance
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }

        let scale = rep.pixelsWide / Int(rect.width)
        return (0 ..< rep.pixelsHigh).map { y in
            (0 ..< rep.pixelsWide).filter { x in
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return abs(pixel.redComponent - 0.5) > 0.1
                    || abs(pixel.greenComponent - 0.5) > 0.1
                    || abs(pixel.blueComponent - 0.5) > 0.1
            }.map { $0 / max(scale, 1) }
        }
    }

    // Flipped like the grid's cell surface, whose baseline is placed from the top edge.
    private final class CellHost: NSView {
        var cellAppearance: DataGridCellAppearance?

        override var isFlipped: Bool { true }

        static let ground = NSColor(calibratedWhite: 0.5, alpha: 1)

        override func draw(_ dirtyRect: NSRect) {
            Self.ground.setFill()
            bounds.fill()
            guard let cellAppearance else { return }
            MainActor.assumeIsolated { DataGridCellRenderer().draw(cellAppearance, in: bounds) }
        }
    }

    private static let cell = NSRect(x: 0, y: 0, width: 160, height: 24)

    // The pixel row where the mark adds the most ink over the unmarked cell, that ink, and how far it reaches.
    private func markedRow(
        _ marked: DataGridCellAppearance,
        against plain: DataGridCellAppearance,
        in rect: NSRect = DataGridPendingChangeMarkTests.cell
    ) throws -> (row: Int, gain: Int, reach: Int) {
        let markedRows = try inkedColumns(of: marked, in: rect)
        let plainRows = try inkedColumns(of: plain, in: rect)
        let gains = zip(markedRows, plainRows).map { $0.count - $1.count }
        let row = try #require(gains.indices.max(by: { gains[$0] < gains[$1] }))
        return (row, gains[row], markedRows[row].max() ?? 0)
    }

    // Gain and reach are asserted apart: a selected row's glyphs are already white, so its rule adds less new ink.
    @Test("A struck-through cell draws a rule its plain twin does not, selected or not")
    func strikeIsDrawn() throws {
        let text = "0123456789"
        let textWidth = Int(text.size(withAttributes: [.font: palette.regularFont]).width)

        let struck = try markedRow(resolve(text: text, visualState: Self.deleted), against: resolve(text: text))
        let selected = try markedRow(
            resolve(text: text, visualState: Self.deleted, onEmphasizedSelection: true),
            against: resolve(text: text, onEmphasizedSelection: true)
        )

        #expect(struck.gain > textWidth / 4)
        #expect(selected.gain > textWidth / 4)
        #expect(struck.reach >= textWidth)
        #expect(selected.reach >= textWidth)
    }

    @Test("The underline sits below the strike")
    func underlineSitsBelowTheStrike() throws {
        let text = "0123456789"
        let plain = resolve(text: text)
        let struck = try markedRow(resolve(text: text, visualState: Self.deleted), against: plain)
        let underlined = try markedRow(resolve(text: text, visualState: Self.inserted), against: plain)

        #expect(underlined.row > struck.row)
    }

    @Test("The mark reaches as far as the text and no further, truncated or not")
    func markStopsWithTheText() throws {
        let short = "0123"
        let inset = DataGridMetrics.cellHorizontalInset
        let textEnd = inset + short.size(withAttributes: [.font: palette.regularFont]).width
        let roomy = NSRect(x: 0, y: 0, width: 300, height: 24)
        let shortMark = try markedRow(
            resolve(text: short, visualState: Self.deleted),
            against: resolve(text: short),
            in: roomy
        )

        #expect(CGFloat(shortMark.reach) <= textEnd + 2)
        #expect(CGFloat(shortMark.reach) > textEnd - 4)

        let long = String(repeating: "0123456789", count: 8)
        let narrow = NSRect(x: 0, y: 0, width: 120, height: 24)
        let truncatedMark = try markedRow(
            resolve(text: long, visualState: Self.deleted),
            against: resolve(text: long),
            in: narrow
        )

        #expect(CGFloat(truncatedMark.reach) <= narrow.width)
        #expect(truncatedMark.reach > shortMark.reach)

        // Reach alone cannot tell: a truncated value's glyphs already reach the cell's edge.
        #expect(truncatedMark.gain > shortMark.gain * 2)
    }
}
