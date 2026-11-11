import Foundation
import Testing

@testable import TableProModels

struct CellTests {
    private static let long = String(repeating: "a", count: 10_000)

    @Test("A budget keeps long values whole until it is spent, then the next keeps only a preview")
    func budgetKeepsWholeUntilSpent() {
        let budget = TextBudget(bytes: 15_000)
        let options = StreamOptions(textBudget: budget)

        guard case .text(let kept) = Cell.from(text: Self.long, options: options) else {
            Issue.record("the first long value should be kept whole")
            return
        }
        #expect(kept == Self.long)
        #expect(!budget.hasRefused)

        guard case .truncatedText(let prefix, let totalBytes, let ref) = Cell.from(text: Self.long, options: options) else {
            Issue.record("the second long value should be cut")
            return
        }
        #expect(prefix.utf8.count == Cell.previewByteLimit)
        #expect(totalBytes == 10_000)
        #expect(ref == nil)
        #expect(budget.hasRefused)
    }

    @Test("A value within the cut spends nothing")
    func shortValuesSpendNothing() {
        let budget = TextBudget(bytes: 10_000)
        let options = StreamOptions(textBudget: budget)
        for _ in 0 ..< 10 {
            _ = Cell.from(text: String(repeating: "b", count: Cell.previewByteLimit), options: options)
        }

        guard case .text = Cell.from(text: Self.long, options: options) else {
            Issue.record("the long value should still fit the budget")
            return
        }
        #expect(!budget.hasRefused)
    }

    @Test("Without a budget every long value is cut")
    func noBudgetCuts() {
        guard case .truncatedText(_, let totalBytes, .none) = Cell.from(text: Self.long, options: .default) else {
            Issue.record("the long value should be cut")
            return
        }
        #expect(totalBytes == 10_000)
    }

    @Test("A value with a ref stays cut and loadable, and spends none of the budget")
    func refValuesSpendNothing() {
        let budget = TextBudget(bytes: 10_000)
        let options = StreamOptions(textBudget: budget)
        let ref = CellRef(table: "notes", column: "body", primaryKey: [PrimaryKeyComponent(column: "id", value: "1")])

        guard case .truncatedText(_, _, let kept?) = Cell.from(text: Self.long, options: options, ref: ref) else {
            Issue.record("a value with a ref should stay cut")
            return
        }
        #expect(kept == ref)
        guard case .text = Cell.from(text: Self.long, options: options) else {
            Issue.record("the budget should be untouched")
            return
        }
    }

    @Test(
        "The preview holds at most the cut in bytes and ends on a whole character",
        arguments: ["界", "👍🏽", "e\u{301}", "x"]
    )
    func previewIsBoundedInBytes(_ unit: String) {
        let value = String(repeating: unit, count: 5_000)

        let preview = Cell.preview(of: value, maxBytes: 4_096)

        #expect(preview.utf8.count <= 4_096)
        #expect(preview.utf8.count > 4_096 - unit.utf8.count)
        #expect(preview == String(repeating: unit, count: preview.count))
    }

    @Test("A cut value's preview is bounded in bytes, not characters")
    func cutPreviewIsBoundedInBytes() {
        let value = String(repeating: "界", count: 5_000)

        guard case .truncatedText(let prefix, let totalBytes, _) = Cell.from(text: value, options: .default) else {
            Issue.record("the value should be cut")
            return
        }
        #expect(prefix.utf8.count <= Cell.previewByteLimit)
        #expect(totalBytes == 15_000)
    }

    @Test(
        "Oracle's BINARY_DOUBLE, BINARY_FLOAT and BINARY_INTEGER hold numbers, not bytes",
        arguments: ["binary_double", "BINARY_FLOAT", "binary_integer"]
    )
    func oracleBinaryNumbersStayText(_ typeName: String) {
        guard case .text(let value) = Cell.from(legacyValue: "1.5", columnTypeName: typeName, options: .default) else {
            Issue.record("\(typeName) should read as text")
            return
        }
        #expect(value == "1.5")
    }

    @Test(
        "A byte type, with or without a length, reads as binary",
        arguments: ["BLOB", "bytea", "VARBINARY(16)", "binary(16)", "LONGBLOB", "image", "BLOB(3)"]
    )
    func byteTypesAreBinary(_ typeName: String) {
        guard case .binary(let byteCount, _) = Cell.from(legacyValue: "0A0B", columnTypeName: typeName, options: .default) else {
            Issue.record("\(typeName) should read as binary")
            return
        }
        #expect(byteCount == 4)
    }

    @Test("Display values cut a long value the cell holds whole")
    func displayValuesCutKeptText() {
        let row = Row(cells: [.text(Self.long), .null, .truncatedText(prefix: "a", totalBytes: 10_000, ref: nil)])

        let shown = row.displayValues()

        #expect(shown[0]?.utf8.count == Cell.previewByteLimit)
        #expect(shown[1] == nil)
        #expect(shown[2] == row.cells[2].displayString)
        #expect(row.legacyValues[0] == Self.long)
    }
}
