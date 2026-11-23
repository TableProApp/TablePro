//
//  XLSXRowEncoderTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

// The cell rule as XLSXWriter wrote it before plain decimals took a byte path, kept as the oracle.
private func cellBeforeFastPath(_ text: String, numbers: PluginColumnNumbers) -> XLSXWriter.CellValue {
    guard !text.isEmpty else { return .empty }
    let digits = text.drop { $0 == "-" || $0 == "+" }
    let padded = digits.first == "0" && digits.dropFirst().first?.isNumber == true
    guard numbers != .text, !padded,
          let literal = JsonNumberNormalizer.numberLiteral(from: text),
          let value = Double(literal), value.isFinite else {
        return .string(text)
    }
    switch numbers {
    case .approximate:
        return .number(literal)
    case .exact:
        let mantissa = literal.prefix { $0 != "e" && $0 != "E" }
        let significant = mantissa.filter(\.isNumber).drop { $0 == "0" }
        let count = significant.lastIndex { $0 != "0" }.map { significant[...$0].count } ?? 0
        return count <= 15 ? .number(literal) : .string(text)
    case .untyped:
        let isPlain = literal == text && !literal.contains("e")
        return isPlain && literal.filter(\.isNumber).count <= 15 ? .number(literal) : .string(text)
    default:
        return .string(text)
    }
}

private func sheetXML(_ build: (XLSXWriter) throws -> Void) async throws -> String {
    let writer = XLSXWriter()
    try build(writer)
    try writer.finishSheet()
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xlsx")
    defer { try? FileManager.default.removeItem(at: destination) }
    try await writer.write(to: destination)
    return try XLSXArchiveContents(contentsOf: destination).xml(of: "xl/worksheets/sheet1.xml")
}

struct XLSXRowEncoderTests {
    @Test("A sheet's XML spells every escape, stripped control, kind of number, bytes and null as before")
    func goldenSheetXML() async throws {
        let xml = try await sheetXML { writer in
            try writer.beginSheet(
                name: "t", columns: ["a", "b&", "c", "d", "e", "f"],
                columnTypeNames: ["text", "text", "int4", "numeric", "", "bytea"],
                includeHeader: true, convertNullToEmpty: false
            )
            try writer.addRows([
                [.text("x&<>\"'\r\n\t\u{01}\u{1F}y"), .text(" pad "), .text("-12"), .text("1.50"), .text("007"),
                 .bytes(Data([0xAB]))],
                [.null, .text(""), .text("1e3"), .text("12345678901234567"), .text("42"), .bytes(Data())],
            ], convertNullToEmpty: false)
        }
        let header = #"<row r="1"><c r="A1" t="inlineStr" s="1"><is><t>a</t></is></c>"#
            + #"<c r="B1" t="inlineStr" s="1"><is><t>b&amp;</t></is></c>"#
            + #"<c r="C1" t="inlineStr" s="1"><is><t>c</t></is></c>"#
            + #"<c r="D1" t="inlineStr" s="1"><is><t>d</t></is></c>"#
            + #"<c r="E1" t="inlineStr" s="1"><is><t>e</t></is></c>"#
            + #"<c r="F1" t="inlineStr" s="1"><is><t>f</t></is></c></row>"#
        let first = #"<row r="2"><c r="A2" t="inlineStr"><is><t>x&amp;&lt;&gt;&quot;&apos;&#13;"# + "\n\t"
            + #"y</t></is></c><c r="B2" t="inlineStr"><is><t xml:space="preserve"> pad </t></is></c>"#
            + #"<c r="C2"><v>-12</v></c><c r="D2"><v>1.50</v></c>"#
            + #"<c r="E2" t="inlineStr"><is><t>007</t></is></c>"#
            + #"<c r="F2" t="inlineStr"><is><t>0xAB</t></is></c></row>"#
        let second = #"<row r="3"><c r="A3" t="inlineStr"><is><t>NULL</t></is></c>"#
            + #"<c r="C3"><v>1e3</v></c><c r="D3" t="inlineStr"><is><t>12345678901234567</t></is></c>"#
            + #"<c r="E3"><v>42</v></c><c r="F3" t="inlineStr"><is><t>0x</t></is></c></row>"#
        let expected = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
            + header + first + second + "</sheetData></worksheet>"
        #expect(xml == expected)
    }

    @Test("Column letters past Z and row numbers past 9 spell the cell reference")
    func cellReferences() async throws {
        let xml = try await sheetXML { writer in
            try writer.beginSheet(
                name: "t", columns: (0..<28).map { "c\($0)" }, includeHeader: false, convertNullToEmpty: true
            )
            try writer.addRows(
                (0..<10).map { _ in (0..<28).map { _ in PluginCellValue.text("v") } }, convertNullToEmpty: true
            )
        }
        #expect(xml.contains(#"<c r="Z10" t="inlineStr">"#))
        #expect(xml.contains(#"<c r="AA10" t="inlineStr">"#))
        #expect(xml.contains(#"<c r="AB1" t="inlineStr">"#))
        #expect(xml.contains(#"<row r="10">"#))
    }

    @Test("The plain decimal path decides every cell as the general rule does")
    func plainDecimalMatchesGeneralRule() {
        var inputs = [
            "0", "-0", "0.0", "-0.50", "1.50", "42", "-12", "007", "0.000120", "1234567890123456789",
            "123456789012345", "1234567890123456", "100000000000000000000", "0.1234567890123456", "1.", ".5",
            "+5", "1e3", "1E5", "NaN", "Infinity", "0x1F", "1.2.3", "--1", "-", "", " 1", "1 ", "١٢", "1_000",
            String(repeating: "9", count: 300), String(repeating: "9", count: 301),
            String(repeating: "9", count: 309) + ".5", "0." + String(repeating: "0", count: 400) + "1",
        ]
        var state: UInt64 = 0xDEC1_3A15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for _ in 0..<2_000 {
            var text = next(4) == 0 ? "-" : ""
            text += String((0..<(1 + next(20))).map { _ in Character(String(next(10))) })
            if next(2) == 0 {
                text += "." + String((0..<(1 + next(20))).map { _ in Character(String(next(10))) })
            }
            inputs.append(text)
        }
        let kinds: [PluginColumnNumbers] = [.exact, .approximate, .untyped, .text]
        for text in inputs {
            for numbers in kinds {
                #expect(
                    XLSXWriter.cell(forText: text, numbers: numbers) == cellBeforeFastPath(text, numbers: numbers),
                    "\(text.debugDescription) \(numbers)"
                )
            }
        }
    }
}
