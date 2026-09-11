import Foundation
import TableProModels
import Testing
@testable import TableProMobile

@Suite("MySQL table listing")
struct MySQLTableListingTests {
    private let rows: [[String?]] = [
        ["orders", "BASE TABLE"],
        ["recent_orders", "VIEW"],
        ["order_seq", "SEQUENCE"]
    ]

    @Test("TiDB leaves sequences out of the table list")
    func tiDBSkipsSequences() {
        let tables = MySQLTableListing.tables(fromShowFullTables: rows, databaseType: .tidb)
        #expect(tables.map(\.name) == ["orders", "recent_orders"])
        #expect(tables.map(\.type) == [.table, .view])
    }

    @Test("MariaDB keeps its sequences")
    func mariaDBKeepsSequences() {
        let tables = MySQLTableListing.tables(fromShowFullTables: rows, databaseType: .mariadb)
        #expect(tables.map(\.name) == ["orders", "recent_orders", "order_seq"])
        #expect(tables.map(\.type) == [.table, .view, .table])
    }

    @Test("a lowercase sequence type is still skipped on TiDB")
    func tiDBSkipsLowercaseSequence() {
        let tables = MySQLTableListing.tables(fromShowFullTables: [["s", "sequence"]], databaseType: .tidb)
        #expect(tables.isEmpty)
    }

    @Test("a row missing its name or type is dropped")
    func incompleteRowsAreDropped() {
        let tables = MySQLTableListing.tables(
            fromShowFullTables: [["t"], [nil, "BASE TABLE"], ["u", nil]],
            databaseType: .mysql
        )
        #expect(tables.isEmpty)
    }
}
