import Foundation
@testable import TableProMobile
import TableProModels
import Testing

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

    /// Measured on MariaDB 11.4.13: `SHOW FULL TABLES` reports a sequence as `SEQUENCE`, and the
    /// engine refuses UPDATE, DELETE and TRUNCATE on one with ERROR 1031.
    @Test("MariaDB keeps its sequences, typed as sequences")
    func mariaDBKeepsSequences() {
        let tables = MySQLTableListing.tables(fromShowFullTables: rows, databaseType: .mariadb)
        #expect(tables.map(\.name) == ["orders", "recent_orders", "order_seq"])
        #expect(tables.map(\.type) == [.table, .view, .sequence])
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

    /// Measured on MySQL 8.4.11: `information_schema`'s own objects are `SYSTEM VIEW` in both
    /// channels. Typed as a table they landed in the Tables section with Truncate and Drop offered.
    @Test("a system view is a view")
    func systemViewIsAView() {
        let tables = MySQLTableListing.tables(fromShowFullTables: [["COLUMNS", "SYSTEM VIEW"]], databaseType: .mysql)
        #expect(tables.map(\.type) == [.view])
    }

    /// Measured on MariaDB 11.4.13 in one session: a temporary table shadowing a base table of the
    /// same name makes `SHOW FULL TABLES` list that name twice. `TableInfo.id` here is the bare
    /// name, so both rows carried one id.
    @Test("a temporary row is dropped so the table it shadows is listed once")
    func temporaryRowsAreDropped() {
        let tables = MySQLTableListing.tables(
            fromShowFullTables: [["plain", "TEMPORARY TABLE"], ["plain", "BASE TABLE"]],
            databaseType: .mariadb
        )
        #expect(tables.map(\.name) == ["plain"])
        #expect(tables.map(\.type) == [.table])
    }

    /// A system or virtual table belongs to the catalog, which `.systemTable` describes.
    @Test("system and virtual tables read as system tables")
    func catalogOwnedTablesAreSystemTables() {
        let tables = MySQLTableListing.tables(
            fromShowFullTables: [["a", "SYSTEM TABLE"], ["b", "VIRTUAL TABLE"]],
            databaseType: .oceanbase
        )
        #expect(tables.map(\.type) == [.systemTable, .systemTable])
    }

    /// Measured on OceanBase CE 4.4.2.1: `SHOW FULL TABLES` reports an external table as
    /// `EXTERNAL TABLE` and the server refuses INSERT on one with ERROR 1235. Folded into
    /// `.systemTable`, which is row-editable, the browser offered Insert Row over it.
    @Test("an external table keeps its own kind and is read-only")
    func externalTableIsReadOnly() {
        let tables = MySQLTableListing.tables(
            fromShowFullTables: [["ext_csv", "EXTERNAL TABLE"]],
            databaseType: .oceanbase
        )
        #expect(tables.map(\.type) == [.externalTable])
        #expect(!TableInfo.TableKind.externalTable.allowsRowEditing)
    }
}

@Suite("Table kind list behaviour")
struct TableKindListBehaviourTests {
    /// Two `==` filters let a kind named in neither fall out of the list entirely, which is what
    /// happened to a MariaDB sequence. Every kind lands in a section now.
    @Test("every kind lands in a section")
    func everyKindHasASection() {
        let tables: Set<TableInfo.TableKind> = [.table, .foreignTable, .systemTable, .externalTable, .sequence]
        for kind in TableInfo.TableKind.allCases {
            let expected: TableInfo.TableKind.ListSection = tables.contains(kind) ? .tables : .views
            #expect(kind.listSection == expected, "\(kind.rawValue) landed in the wrong section")
        }
    }

    /// Measured on MariaDB 11.4.13: `TRUNCATE` on a sequence fails ERROR 1031, and `DROP TABLE` on
    /// one succeeds.
    @Test("Truncate is offered on a table alone, Drop on a table and a sequence")
    func destructiveCommandsFollowTheKind() {
        for kind in TableInfo.TableKind.allCases {
            #expect(kind.allowsTruncate == (kind == .table), "\(kind.rawValue) offers the wrong Truncate")
            #expect(kind.allowsDrop == (kind == .table || kind == .sequence), "\(kind.rawValue) offers the wrong Drop")
        }
    }

    /// A view holds no rows of its own, a sequence refuses UPDATE and DELETE with ERROR 1031 on
    /// MariaDB 11.4.13, and an external table refuses INSERT with ERROR 1235 on OceanBase CE
    /// 4.4.2.1. A system table is the catalog's own and stays editable, as it is on Mac.
    @Test("row editing follows the kind")
    func rowEditingFollowsTheKind() {
        let editable: Set<TableInfo.TableKind> = [.table, .foreignTable, .systemTable]
        for kind in TableInfo.TableKind.allCases {
            #expect(kind.allowsRowEditing == editable.contains(kind), "\(kind.rawValue) is wrongly editable")
        }
    }
}
