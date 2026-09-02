import Foundation
import Testing

@testable import TablePro

@Suite("ForeignKeyConstraintSpan")
struct ForeignKeyConstraintSpanTests {
    private func info(
        name: String,
        column: String,
        referencedTable: String = "orders",
        referencedColumn: String? = nil
    ) -> ForeignKeyInfo {
        ForeignKeyInfo(
            name: name,
            column: column,
            referencedTable: referencedTable,
            referencedColumn: referencedColumn ?? column
        )
    }

    private func byColumn(_ infos: [ForeignKeyInfo]) -> [String: ForeignKeyInfo] {
        Dictionary(infos.map { ($0.column, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("A single-column constraint spans one column")
    func singleColumnConstraint() {
        let reference = info(name: "fk_order", column: "order_id")
        #expect(!ForeignKeyConstraintSpan.isMultiColumn(reference, among: byColumn([reference])))
    }

    @Test("Two columns of one constraint span it together")
    func compositeConstraint() {
        let first = info(name: "fk_line", column: "order_id")
        let second = info(name: "fk_line", column: "line_no")
        let all = byColumn([first, second])
        #expect(ForeignKeyConstraintSpan.isMultiColumn(first, among: all))
        #expect(ForeignKeyConstraintSpan.isMultiColumn(second, among: all))
    }

    @Test("Two constraints on one table stay separate")
    func separateConstraintsOnOneTable() {
        let first = info(name: "fk_billing", column: "billing_order_id")
        let second = info(name: "fk_shipping", column: "shipping_order_id")
        #expect(!ForeignKeyConstraintSpan.isMultiColumn(first, among: byColumn([first, second])))
    }

    /// A name a driver reuses across tables is not evidence of one constraint, so the referenced
    /// table has to agree too.
    @Test("The same name against a different table is a different constraint")
    func sameNameDifferentTable() {
        let first = info(name: "fk", column: "order_id", referencedTable: "orders")
        let second = info(name: "fk", column: "user_id", referencedTable: "users")
        #expect(!ForeignKeyConstraintSpan.isMultiColumn(first, among: byColumn([first, second])))
    }

    /// A driver that reports no name cannot be asked, and the answer costs a picker rather than a
    /// write the server refuses.
    @Test("An unnamed constraint is read as single-column")
    func unnamedConstraint() {
        let first = info(name: "", column: "order_id")
        let second = info(name: "", column: "line_no")
        #expect(!ForeignKeyConstraintSpan.isMultiColumn(first, among: byColumn([first, second])))
    }
}
