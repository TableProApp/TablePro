//
//  ExternalAnswerBudgetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ExternalAnswerBudgetTests {
    private func result(_ column: String, _ rows: [[PluginCellValue]], isTruncated: Bool = false) -> QueryResult {
        var result = QueryResult(
            columns: [column],
            columnTypes: [.text(rawType: nil)],
            rows: rows,
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
        result.isTruncated = isTruncated
        return result
    }

    private func textRows(_ column: String, count: Int, bytes: Int) -> QueryResult {
        result(column, Array(repeating: [.text(String(repeating: "x", count: bytes))], count: count))
    }

    // What one row of a single column costs in the core's measure: the row's brackets and comma, then the name, the
    // cell's quotes, colon and comma, and the value.
    private func rowCost(column: String, valueBytes: Int) -> Int {
        3 + column.utf8.count + 6 + valueBytes
    }

    @Test("A value past 64 KiB keeps its first 64 KiB and a mark with its full length")
    func longTextIsCut() throws {
        var budget = ExternalAnswerBudget.mcpAnswer

        let kept = budget.keep(result("body", [[.text(String(repeating: "a", count: 200_000))]]))

        let cell = try #require(kept.rows.first?.first)
        #expect(cell == .text(String(repeating: "a", count: 65_536) + " [TablePro cut this value: 200000 bytes in all]"))
        #expect(budget.valuesCut)
        #expect(!budget.sizeLimited)
        #expect(!kept.isTruncated)
        #expect(budget.notes.count == 1)
    }

    @Test("A cut never splits a character, and a value inside the limit is left as it is")
    func cutKeepsWholeCharacters() {
        let euros = String(repeating: "€", count: 30_000)

        let cut = ExternalAnswerBudget.cut(euros)

        let mark = " [TablePro cut this value: 90000 bytes in all]"
        #expect(cut.hasSuffix(mark))
        #expect(String(cut.dropLast(mark.count)) == String(repeating: "€", count: 21_845))
        #expect(ExternalAnswerBudget.cut("short") == "short")
    }

    @Test("Binary is measured as the base64 the answer carries, and a long one is cut to base64 text")
    func binaryIsMeasuredAsBase64() throws {
        let row = result("b", [[.bytes(Data(repeating: 7, count: 3_000))]])
        let cost = rowCost(column: "b", valueBytes: 4_000)

        var fits = ExternalAnswerBudget(bytes: cost)
        var short = ExternalAnswerBudget(bytes: cost - 1)
        let fitted = fits.keep(row)
        let shortened = short.keep(row)

        #expect(fitted.rows.count == 1)
        #expect(shortened.rows.isEmpty)
        #expect(short.sizeLimited)

        let data = Data(repeating: 1, count: 100_000)
        var budget = ExternalAnswerBudget.mcpAnswer
        let kept = budget.keep(result("b", [[.bytes(data)]]))
        let cell = try #require(kept.rows.first?.first)
        #expect(cell == .text(data.prefix(49_152).base64EncodedString() + " [TablePro cut this value: 100000 bytes in all]"))
    }

    @Test("Rows past the answer limit are left out, and the result says it was truncated")
    func rowsPastTheLimitAreLeftOut() {
        var budget = ExternalAnswerBudget.mcpAnswer

        let kept = budget.keep(textRows("body", count: 3_000, bytes: 2_000))

        #expect(kept.rows.count == ExternalAnswerBudget.answerBytes / rowCost(column: "body", valueBytes: 2_000))
        #expect(kept.isTruncated)
        #expect(budget.sizeLimited)
        #expect(!budget.valuesCut)
        #expect(budget.spentBytes <= ExternalAnswerBudget.answerBytes)
        #expect(budget.notes.count == 1)
    }

    @Test("An export keeps a long value whole, and leaves out a row that does not fit instead of cutting it")
    func exportKeepsValuesWhole() {
        let long = String(repeating: "y", count: 100_000)
        var export = ExternalAnswerBudget.export

        let kept = export.keep(result("doc", [[.text(long)]]))

        #expect(kept.rows == [[.text(long)]])
        #expect(!export.valuesCut)

        var small = ExternalAnswerBudget(bytes: 50_000, longValues: .whole)
        let leftOut = small.keep(result("doc", [[.text(long)]]))
        #expect(leftOut.rows.isEmpty)
        #expect(leftOut.isTruncated)
        #expect(small.sizeLimited)
        #expect(!small.valuesCut)
    }

    @Test("A result after the limit was reached keeps no rows")
    func laterResultKeepsNoRows() {
        var budget = ExternalAnswerBudget(bytes: 100)

        let first = budget.keep(textRows("a", count: 1, bytes: 200))
        let second = budget.keep(textRows("b", count: 1, bytes: 1))

        #expect(first.rows.isEmpty)
        #expect(second.rows.isEmpty)
        #expect(second.isTruncated)
    }

    @Test("A result the answer writes twice costs twice")
    func weightCountsEveryCopy() {
        let rows = textRows("b", count: 6, bytes: 1_000)
        var once = ExternalAnswerBudget(bytes: 10_000)
        var twice = ExternalAnswerBudget(bytes: 10_000)
        let keptOnce = once.keep(rows)
        let keptTwice = twice.keep(rows, weight: 2)

        #expect(keptOnce.rows.count == 6)
        #expect(keptTwice.rows.count == 4)
    }

    @Test("A text beside the rows is cut to what the answer has left")
    func textIsCutToTheRest() {
        var budget = ExternalAnswerBudget(bytes: 100)

        let kept = budget.keep(text: String(repeating: "p", count: 300))

        #expect(kept == String(repeating: "p", count: 100) + " [TablePro cut this value: 300 bytes in all]")
        #expect(budget.sizeLimited)
        #expect(budget.remainingBytes == 0)
    }

    @Test("A part kept only whole is left out when it does not fit, and a smaller part after it still fits")
    func wholePartIsLeftOut() {
        var budget = ExternalAnswerBudget(bytes: 1_000)

        let large = budget.keepWhole(bytes: 1_200)
        let small = budget.keepWhole(bytes: 800)

        #expect(!large)
        #expect(small)
        #expect(budget.spentBytes == 800)
        #expect(!budget.sizeLimited)
    }

    @Test("An answer that fits comes back as it was, with no notes")
    func fittingAnswerIsUntouched() {
        var budget = ExternalAnswerBudget.mcpAnswer
        let rows = textRows("n", count: 10, bytes: 10)

        let kept = budget.keep(rows)

        #expect(kept.rows == rows.rows)
        #expect(!kept.isTruncated)
        #expect(budget.notes.isEmpty)
        #expect(budget.spentBytes == 10 * rowCost(column: "n", valueBytes: 10))
    }
}
