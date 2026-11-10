import Foundation
@testable import TablePro
import Testing

@MainActor
struct TableHealthFindingsTableTests {
    private static func row(_ table: String?, schema: String? = "public", kind: TableHealthCheckKind = .missingPrimaryKey) -> TableHealthFindingRow {
        TableHealthFindingRow(
            finding: TableHealthFixture.finding(kind, schema: schema, table: table),
            checkTitle: kind.title,
            checkOrder: 0,
            status: .seen,
            firstSeen: nil,
            lastSeen: nil
        )
    }

    @Test("Open Table applies to findings that all name one table")
    func oneTableAcrossFindings() {
        let rows = [Self.row("orders"), Self.row("orders", kind: .unusedIndex), Self.row(nil)]

        #expect(TableHealthFindingsTable.singleTableFinding(in: rows)?.table == "orders")
    }

    @Test("Open Table does not apply across two tables, or one name in two schemas")
    func twoTablesHaveNoSingleTable() {
        #expect(TableHealthFindingsTable.singleTableFinding(in: [Self.row("orders"), Self.row("events")]) == nil)
        #expect(TableHealthFindingsTable.singleTableFinding(in: [Self.row("orders"), Self.row("orders", schema: "audit")]) == nil)
        #expect(TableHealthFindingsTable.singleTableFinding(in: [Self.row(nil)]) == nil)
    }
}
