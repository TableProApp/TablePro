//
//  DataGridCellTextTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct DataGridCellTextTests {
    // The rule the cell has always followed, walked one UTF-16 unit at a time.
    private func flattened(_ text: String, keepingLoneCarriageReturns: Bool) -> String {
        let units = Array(text.utf16)
        var output: [UInt16] = []
        for (index, unit) in units.enumerated() {
            let isBreak = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029].contains(unit)
            let isLoneReturn = unit == 0x0D && (index + 1 >= units.count || units[index + 1] != 0x0A)
            output.append(isBreak && !(isLoneReturn && keepingLoneCarriageReturns) ? 0x20 : unit)
        }
        return String(decoding: output, as: UTF16.self)
    }

    @Test(
        "Flattening puts one space per break and keeps everything else",
        arguments: [
            "", "plain", "a\nb", "a\r\nb", "a\rb", "a\r", "\r", "\n\n", "a\u{0B}b\u{0C}c",
            "a\u{85}b", "a\u{2028}b\u{2029}c", "Việt\nNam\u{2028}đẹp", "😀\n😀", "\u{C2}\u{85}",
            "é\u{0301}\r\n", "tab\tstays", "\u{2027}\u{202A}\u{84}\u{86}", String(repeating: "dòng\n", count: 400),
        ]
    )
    func flatteningMatchesTheUnitRule(text: String) {
        #expect(text.flattenedForCell == flattened(text, keepingLoneCarriageReturns: true))
        #expect(text.sanitizedForCellDisplay == flattened(text, keepingLoneCarriageReturns: false))
    }

    @Test(
        "A wrapping cell keeps each break as one LF and drops one that ends the value",
        arguments: [
            ("plain", "plain"), ("a\nb", "a\nb"), ("a\r\nb", "a\nb"), ("a\rb", "a\nb"), ("a\u{0B}b\u{0C}c", "a\nb\nc"),
            ("a\u{85}b", "a\nb"), ("a\u{2028}b\u{2029}c", "a\nb\nc"), ("a\n", "a"), ("a\r\n", "a"), ("a\n\n", "a\n"),
            ("\n", ""), ("a\r\n\r\nb", "a\n\nb"), ("Việt\u{2028}Nam\r", "Việt\nNam"), ("", ""),
        ]
    )
    func wrappingKeepsLineBreaks(text: String, expected: String) {
        #expect(text.keepingLineBreaksForCell == expected)
    }

    @Test("A value with no break comes back as it was")
    func unbrokenTextIsUnchanged() {
        let text = String(repeating: "Tiếng Việt ", count: 1_000)
        #expect(text.flattenedForCell == text)
    }

    @Test(
        "Line breaks are found in every encoding width",
        arguments: [
            ("plain", false), ("a\nb", true), ("a\rb", true), ("a\u{0B}", true), ("\u{0C}", true),
            ("a\u{85}", true), ("a\u{2028}", true), ("\u{2029}a", true), ("\u{2027}\u{202A}\u{84}", false), ("Việt", false),
        ]
    )
    func lineBreaksAreFound(text: String, expected: Bool) {
        #expect(text.containsLineBreak == expected)
    }

    @Test("Text within the limit is not clipped, in UTF-16 units and not bytes")
    func textWithinTheLimitStaysWhole() {
        #expect("abc".clipped(toUTF16Units: 3) == nil)
        #expect(String(repeating: "đ", count: 10).clipped(toUTF16Units: 10) == nil)
        #expect("😀😀".clipped(toUTF16Units: 4) == nil)
    }

    @Test("Clipping keeps the first units and never splits a surrogate pair")
    func clippingKeepsWholeScalars() {
        #expect("abcdef".clipped(toUTF16Units: 3) == "abc")
        #expect("đêm khuya".clipped(toUTF16Units: 3) == "đêm")
        #expect("a😀b".clipped(toUTF16Units: 2) == "a")
        #expect("a😀b".clipped(toUTF16Units: 3) == "a😀")
    }

    // MARK: - Drawing

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    private func bitmap(width: Int = 240, height: Int = 24, scale: Int, _ body: () -> Void) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width * scale,
            pixelsHigh: height * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = NSSize(width: width, height: height)
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        flipped.cgContext.translateBy(x: 0, y: CGFloat(height))
        flipped.cgContext.scaleBy(x: 1, y: -1)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        body()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.tiffRepresentation)
    }

    private func appearance(_ text: String) -> DataGridCellAppearance {
        let palette = DataGridCellPalette(
            regularFont: font,
            italicFont: font,
            mediumFont: font,
            text: .black,
            placeholderText: .gray,
            booleanTrueText: .black,
            booleanFalseText: .black,
            valueColors: DataGridValueColors(all: .black),
            rowNumberText: .gray,
            deletedRowText: .red,
            modifiedColumnTint: .yellow,
            findMatchTint: .yellow,
            selectionText: .white,
            focusBorder: .blue
        )
        return DataGridCellAppearance.resolve(
            kind: .text,
            content: DataGridCellContent(displayText: text, rawValue: text, placeholder: nil),
            state: DataGridCellState(visualState: .empty, isEditable: false, isCurrentFindMatch: false, row: 0, columnIndex: 0),
            palette: palette,
            nullDisplayString: "NULL",
            onEmphasizedSelection: false,
            revealsInvisibleCharacters: false
        )
    }

    @Test("A row number lands where string drawing puts it", arguments: [1, 2], [18.0, 21.0, 24.0, 33.0])
    func rowNumberMatchesStringDrawing(scale: Int, rowHeight: CGFloat) throws {
        let rect = NSRect(x: 0, y: 0, width: 120, height: rowHeight)
        let renderer = DataGridCellRenderer()
        for number in [7, 1_234, 1_000_000] {
            let drawn = try bitmap(scale: scale) {
                renderer.drawRowNumber(number, in: rect, font: font, color: .black)
            }
            let expected = try bitmap(scale: scale) {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                let text = String(number) as NSString
                let size = text.size(withAttributes: attributes)
                let inset = DataGridMetrics.cellHorizontalInset
                text.draw(
                    at: NSPoint(x: max(rect.minX + inset, rect.maxX - inset - size.width), y: rect.midY - size.height / 2),
                    withAttributes: attributes
                )
            }
            #expect(drawn == expected)
        }
    }

    @Test("A value drawn at another width truncates for that width")
    func truncationFollowsTheWidth() throws {
        let text = appearance(String(repeating: "wide value ", count: 12))
        let shared = DataGridCellRenderer()
        func drawing(width: CGFloat, by renderer: DataGridCellRenderer) throws -> Data {
            try bitmap(scale: 2) { renderer.draw(text, in: NSRect(x: 0, y: 0, width: width, height: 24)) }
        }

        let narrow = try drawing(width: 90, by: shared)
        let wide = try drawing(width: 180, by: shared)
        let narrowAgain = try drawing(width: 90, by: shared)

        #expect(narrow != wide)
        #expect(narrow == narrowAgain)
        #expect(wide == (try drawing(width: 180, by: DataGridCellRenderer())))
    }

    @Test("A value past the laid out length never borrows the line of its own whole prefix")
    func clippedValueKeepsItsEllipsis() throws {
        let prefix = String(repeating: "x", count: 300)
        let renderer = DataGridCellRenderer()
        func drawing(_ text: String) throws -> Data {
            try bitmap(width: 3_000, scale: 1) {
                renderer.draw(appearance(text), in: NSRect(x: 0, y: 0, width: 3_000, height: 24))
            }
        }

        let whole = try drawing(prefix)
        let clipped = try drawing(prefix + "y")
        let clippedElsewhere = try drawing(prefix + "z")

        #expect(whole != clipped)
        #expect(clipped == clippedElsewhere)
    }
}
