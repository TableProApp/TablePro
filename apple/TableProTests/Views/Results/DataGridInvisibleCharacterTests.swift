//
//  DataGridInvisibleCharacterTests.swift
//  TableProTests
//

import AppKit
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct DataGridInvisibleCharacterTests {
    private let palette = DataGridCellPalette(
        regularFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        italicFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        mediumFont: .monospacedSystemFont(ofSize: 13, weight: .medium),
        text: .black,
        placeholderText: .secondaryLabelColor,
        booleanTrueText: .black,
        booleanFalseText: .black,
        rowNumberText: .secondaryLabelColor,
        deletedRowText: .systemRed,
        modifiedColumnTint: .systemYellow,
        findMatchTint: .systemYellow,
        selectionText: .white
    )

    private func resolve(
        _ text: String,
        kind: DataGridCellKind = .text,
        placeholder: DataGridCellPlaceholder? = nil,
        reveals: Bool = true,
        isCurrentFindMatch: Bool = false,
        onEmphasizedSelection: Bool = false
    ) -> DataGridCellAppearance {
        DataGridCellAppearance.resolve(
            kind: kind,
            content: DataGridCellContent(displayText: text, rawValue: text, placeholder: placeholder),
            state: DataGridCellState(
                visualState: .empty,
                isFocused: false,
                isEditable: true,
                isLargeDataset: false,
                isCurrentFindMatch: isCurrentFindMatch,
                row: 0,
                columnIndex: 0
            ),
            palette: palette,
            nullDisplayString: "NULL",
            onEmphasizedSelection: onEmphasizedSelection,
            hasOverlay: false,
            revealsInvisibleCharacters: reveals
        )
    }

    // MARK: - Which cells are marked

    @Test("A value is marked in orange while the setting is on, and not at all while it is off")
    func markColorFollowsTheSetting() {
        #expect(resolve("abc\u{200B}").specialCharacterColor == .systemOrange)
        #expect(resolve("abc\u{200B}", reveals: false).specialCharacterColor == nil)
    }

    @Test("A placeholder and a checkbox are never marked")
    func placeholdersAreNotValues() {
        #expect(resolve("", placeholder: .null).specialCharacterColor == nil)
        #expect(resolve("", placeholder: .empty).specialCharacterColor == nil)
        #expect(resolve("1", kind: .checkbox).specialCharacterColor == nil)
    }

    @Test("Over a selection or a find match the marks take the text's own color")
    func marksFollowTheCellFill() {
        #expect(resolve("a\u{200B}", onEmphasizedSelection: true).specialCharacterColor == palette.selectionText)
        #expect(resolve("a\u{200B}", isCurrentFindMatch: true).specialCharacterColor == palette.findMatchText)
    }

    // MARK: - The display text

    @Test("The cell text keeps a lone CR and flattens LF and CRLF")
    func loneCarriageReturnSurvivesFlattening() {
        #expect(CellDisplayFormatter.format(.text("abc\r"), columnType: nil) == "abc\r")
        #expect(CellDisplayFormatter.format(.text("a\r\nb\nc"), columnType: nil) == "a  b c")
        #expect("abc\r".sanitizedForCellDisplay == "abc ")
    }

    @Test("A marked CR is read by name, as every other mark is")
    func carriageReturnIsSpoken() {
        let revealed = RevealedText("abc\r", marksLineBreaks: true)

        #expect(revealed.revealsAnyCharacter)
        #expect(revealed.spokenText.contains("carriage return"))
        #expect(!RevealedText("abc\r").revealsAnyCharacter)
    }

    @Test("Size to Fit makes room for the marks a value draws")
    func fitWidthCountsTheMarks() {
        let rows = TableRows.from(
            queryRows: [[.text(String(repeating: "x", count: 20) + "\u{200B}\u{FEFF}")]],
            columns: ["v"],
            columnTypes: [.text(rawType: nil)]
        )
        let factory = DataGridCellFactory()
        let marked = factory.calculateFitToContentWidth(
            for: "v", columnIndex: 0, tableRows: rows, availableWidth: 1_600, revealsInvisibleCharacters: true
        )
        let unmarked = factory.calculateFitToContentWidth(
            for: "v", columnIndex: 0, tableRows: rows, availableWidth: 1_600, revealsInvisibleCharacters: false
        )

        #expect(marked > unmarked + 20)
    }

    // MARK: - What is drawn

    private static let cell = NSRect(x: 0, y: 0, width: 200, height: 24)

    @Test("A zero-width space draws an orange box after the text, and nothing while marks are off")
    func zeroWidthSpaceIsDrawn() throws {
        let marked = try ink(of: resolve("abc\u{200B}"))
        let unmarked = try ink(of: resolve("abc\u{200B}", reveals: false))
        let plain = try ink(of: resolve("abc"))
        let textEnd = DataGridMetrics.cellHorizontalInset
            + ("abc" as NSString).size(withAttributes: [.font: palette.regularFont]).width

        #expect(marked.orange > 0)
        #expect(CGFloat(marked.reach) > textEnd + 8)
        #expect(unmarked.orange == 0)
        #expect(unmarked.reach == plain.reach)
    }

    @Test("A lone CR draws as a box while marked and as the old space while not")
    func carriageReturnIsDrawn() throws {
        #expect(try ink(of: resolve("abc\r")).orange > 0)
        #expect(try ink(of: resolve("abc\r", reveals: false)) == ink(of: resolve("abc ", reveals: false)))
    }

    @Test("Marks past the ellipsis of a truncated value are not drawn")
    func truncatedMarksStayHidden() throws {
        let long = String(repeating: "0123456789", count: 6) + "\u{200B}"
        #expect(try ink(of: resolve(long)).orange == 0)
        #expect(try ink(of: resolve("\u{200B}" + long)).orange > 0)
    }

    private struct Ink: Equatable {
        let orange: Int
        let reach: Int
    }

    private func ink(of appearance: DataGridCellAppearance) throws -> Ink {
        let host = CellHost(frame: Self.cell)
        host.cellAppearance = appearance
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        let scale = max(rep.pixelsWide / Int(Self.cell.width), 1)
        var orange = 0
        var reach = 0
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      pixel.redComponent < 0.9 || pixel.greenComponent < 0.9 || pixel.blueComponent < 0.9 else { continue }
                reach = max(reach, x / scale)
                if pixel.redComponent > 0.8, pixel.greenComponent > 0.3, pixel.greenComponent < 0.75, pixel.blueComponent < 0.3 {
                    orange += 1
                }
            }
        }
        return Ink(orange: orange, reach: reach)
    }

    private final class CellHost: NSView {
        var cellAppearance: DataGridCellAppearance?

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            bounds.fill()
            guard let cellAppearance else { return }
            MainActor.assumeIsolated { DataGridCellRenderer().draw(cellAppearance, in: bounds) }
        }
    }
}
