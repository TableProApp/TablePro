//
//  DataGridPendingChangeMarkTests.swift
//  TableProTests
//
//  A pending change used to show as a tint and nothing else, so selecting the rows about to be
//  saved hid every mark at once and a client reading the grid was told nothing at all. These cover
//  the line the cell draws instead, which selection cannot paint over.
//

import AppKit
import CoreText
import Testing

@testable import TablePro

@Suite("Pending change marks")
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
                isFocused: false,
                isEditable: true,
                isLargeDataset: false,
                isCurrentFindMatch: isCurrentFindMatch,
                row: 0,
                columnIndex: columnIndex
            ),
            palette: palette,
            nullDisplayString: "NULL",
            onEmphasizedSelection: onEmphasizedSelection,
            hasOverlay: false
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

    /// The row is going away whatever was typed into it first, so one line wins rather than two
    /// crossing each other.
    @Test("A deleted row that was edited first keeps the strike alone")
    func deleteOutranksTheEdit() {
        let state = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [1])

        #expect(resolve(visualState: state, columnIndex: 1).textMark == .struckThrough)
    }

    /// The whole point: the tint stands down under a selection and the find highlight, and the mark
    /// does not.
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

    /// `CTLineDraw` draws both lines itself from the font's metrics, so these rasterise a cell and
    /// read the pixels rather than trusting the attribute to have any effect.
    ///
    /// Drawn over mid grey, not white: a selected cell's text is
    /// `alternateSelectedControlTextColor`, which is white, and a white-on-white cell rasterises
    /// blank whatever it drew. Ink is any pixel that differs from the ground.
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

    /// Flipped, because the grid's own cell surface is and the renderer positions its baseline from
    /// the top edge. Rasterising into an unflipped context draws the cell upside down, which is how
    /// a first pass at these tests came to read the underline as sitting above the strike.
    ///
    /// Mid grey, not white: a selected cell's text is `alternateSelectedControlTextColor`, which is
    /// white, and a white-on-white cell rasterises blank whatever it drew.
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

    /// Where the mark landed: the row whose ink the mark adds over the same cell drawn unmarked, how
    /// much it added, and how far right its own ink reaches. A glyph row gains nothing, so the
    /// largest gain is the rule itself. The gain undercounts the rule's length wherever it crosses a
    /// glyph the plain cell already inked, which is why reach is measured separately.
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

    @Test("A struck-through cell draws a rule its plain twin does not, selected or not")
    func strikeIsDrawn() throws {
        let text = "0123456789"
        let textWidth = Int(text.size(withAttributes: [.font: palette.regularFont]).width)

        let struck = try markedRow(resolve(text: text, visualState: Self.deleted), against: resolve(text: text))
        let selected = try markedRow(
            resolve(text: text, visualState: Self.deleted, onEmphasizedSelection: true),
            against: resolve(text: text, onEmphasizedSelection: true)
        )

        #expect(struck.gain > textWidth / 2)
        #expect(selected.reach > textWidth / 2)
    }

    /// The two lines have to land in different places, or they are the same cue twice.
    @Test("The underline sits below the strike")
    func underlineSitsBelowTheStrike() throws {
        let text = "0123456789"
        let plain = resolve(text: text)
        let struck = try markedRow(resolve(text: text, visualState: Self.deleted), against: plain)
        let underlined = try markedRow(resolve(text: text, visualState: Self.inserted), against: plain)

        #expect(underlined.row > struck.row)
    }

    /// A cell too narrow for its value truncates, and the mark has to stop where the text does
    /// rather than run on across the rest of the cell.
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

        /// Reach alone cannot see this: the glyphs of a truncated value already run to the cell's
        /// edge, so a line that lost its mark reaches just as far. Only the gain separates them,
        /// measured at 158 with the rule against 67 without it, beside the short cell's 50. So the
        /// rule carried onto the truncated line is asserted where a regression would actually show.
        #expect(truncatedMark.gain > shortMark.gain * 2)
    }
}
