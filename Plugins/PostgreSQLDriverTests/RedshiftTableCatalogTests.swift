import Foundation
import TableProPluginKit
import Testing

struct RedshiftTableCatalogTests {
    @Test("any listed type naming a view is a view, everything else a table")
    func listingTypes() {
        let rows: [[String?]] = [["orders", "BASE TABLE"], ["recent", "VIEW"], ["catalog", "SYSTEM VIEW"], ["bare", nil]]

        let tables = rows.compactMap { RedshiftTableCatalog.table(fromListingRow: $0) }

        #expect(tables.map(\.name) == ["orders", "recent", "catalog", "bare"])
        #expect(tables.map(\.type) == ["TABLE", "VIEW", "VIEW", "TABLE"])
        #expect(RedshiftTableCatalog.table(fromListingRow: [nil, "VIEW"]) == nil)
    }

    @Test("a distribution key and the sort key columns in sort order")
    func distributionAndSortKeys() {
        let rows: [[String?]] = [
            ["id", "integer", "true", "1"],
            ["created_at", "timestamp", "false", "2"],
            ["region", "varchar(16)", "f", "-1"],
            ["ignored", "integer", "f", "not a number"]
        ]

        let keys = RedshiftTableCatalog.keys(fromRows: rows)

        #expect(keys.map(\.name) == ["DISTKEY", "SORTKEY"])
        #expect(keys.map(\.type) == ["DISTKEY", "SORTKEY"])
        #expect(keys.first?.columns == ["id"])
        #expect(keys.last?.columns == ["id", "created_at", "region"])
    }

    @Test("a table with neither key has no rows to report")
    func noKeys() {
        #expect(RedshiftTableCatalog.keys(fromRows: []).isEmpty)
    }
}
