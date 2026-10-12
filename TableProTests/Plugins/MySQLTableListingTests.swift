//
//  MySQLTableListingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MySQLTableListingTests {
    private func row(_ cells: String?...) -> [PluginCellValue] {
        cells.map(PluginCellValue.fromOptional)
    }

    /// Measured on MySQL 8.4.11: an account that can list a database but none of its tables gets an
    /// empty catalog answer, and `SHOW FULL TABLES` there answers `ERROR 1044`.
    @Test("A refusal the server sent is settled by SHOW FULL TABLES")
    func serverRefusalsFallBack() {
        for code: UInt32 in [1_044, 1_064, 1_142, 1_146, 1_235, 3_024, 4_031] {
            #expect(MySQLTableListing.showFullTablesSettlesCatalogFailure(code: code), "code \(code)")
        }
    }

    @Test("A client failure is not retried with a second read")
    func clientFailuresPropagate() {
        for code: UInt32 in [2_002, 2_006, 2_013, 2_055, 2_999] {
            #expect(!MySQLTableListing.showFullTablesSettlesCatalogFailure(code: code), "code \(code)")
        }
    }

    @Test("An error the driver raised itself is not a server answer")
    func driverErrorsPropagate() {
        #expect(!MySQLTableListing.showFullTablesSettlesCatalogFailure(code: 0))
    }

    @Test("A SHOW FULL TABLES row lists its table and view with no comment or partitions")
    func showFullTablesRows() {
        let tables = MySQLTableListing.tables(
            from: [row("orders", "BASE TABLE"), row("active_orders", "VIEW")],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.name) == ["active_orders", "orders"])
        #expect(tables.map(\.type) == ["VIEW", "TABLE"])
        #expect(tables.allSatisfy { $0.comment == nil && $0.partitionCount == nil })
    }

    @Test("A catalog row carries the comment and the partition count")
    func catalogRows() {
        let tables = MySQLTableListing.tables(
            from: [
                row("events", "BASE TABLE", "Audit trail", "4"),
                row("users", "BASE TABLE", "", nil),
                row("recent", "VIEW", "VIEW", nil)
            ],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.name) == ["events", "recent", "users"])
        #expect(tables.map(\.type) == ["PARTITIONED TABLE", "VIEW", "TABLE"])
        #expect(tables.map(\.comment) == ["Audit trail", nil, nil])
        #expect(tables.map(\.partitionCount) == [4, nil, nil])
    }

    @Test("A system view reads as a view")
    func systemViewIsAView() {
        let tables = MySQLTableListing.tables(from: [row("COLUMNS", "SYSTEM VIEW")], listsSequencesAsTables: true)
        #expect(tables.map(\.type) == ["VIEW"])
    }

    /// One case per raw type the three servers were measured answering with. MariaDB 11.4.13
    /// answers `SEQUENCE` and `SYSTEM VERSIONED`, MySQL 8.4.11 answers `BASE TABLE` and
    /// `SYSTEM VIEW`, and OceanBase adds `EXTERNAL TABLE`, `SYSTEM TABLE`, `VIRTUAL TABLE` and
    /// `TMP TABLE`. Anything else is a table, which is what keeps an unfamiliar row listed.
    @Test("Each raw type the servers answer with maps to one emitted type")
    func rawTypesMapToEmittedTypes() {
        let cases: [(rawType: String, emitted: String)] = [
            ("BASE TABLE", "TABLE"),
            ("TABLE", "TABLE"),
            ("VIEW", "VIEW"),
            ("SYSTEM VIEW", "VIEW"),
            ("SEQUENCE", "SEQUENCE"),
            ("SYSTEM VERSIONED", "SYSTEM VERSIONED TABLE"),
            ("TMP TABLE", "TABLE"),
            ("EXTERNAL TABLE", "EXTERNAL TABLE"),
            ("SYSTEM TABLE", "SYSTEM TABLE"),
            ("VIRTUAL TABLE", "SYSTEM TABLE"),
            ("UNKNOWN", "TABLE"),
        ]

        for testCase in cases {
            let tables = MySQLTableListing.tables(
                from: [row("t", testCase.rawType)], listsSequencesAsTables: true
            )
            #expect(tables.map(\.type) == [testCase.emitted], "\(testCase.rawType)")
        }
    }

    /// Measured on MariaDB 11.4.13 in one session: a temporary table shadowing a base table of the
    /// same name is listed twice, as `TEMPORARY TABLE` then `BASE TABLE` by `SHOW FULL TABLES` and
    /// as `TEMPORARY` then `BASE TABLE` by the catalog. Both rows share one `TableInfo.id`.
    @Test(
        "A temporary row is dropped so the table it shadows is listed once",
        arguments: ["TEMPORARY", "TEMPORARY TABLE"]
    )
    func temporaryRowsAreDropped(temporaryType: String) {
        let tables = MySQLTableListing.tables(
            from: [row("plain", temporaryType), row("plain", "BASE TABLE")],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.name) == ["plain"])
        #expect(tables.map(\.type) == ["TABLE"])
    }

    /// A sequence has no comment and no partitions of its own, so neither cell rides along even
    /// when the catalog read put something in them.
    @Test("A sequence carries no comment and no partition count")
    func sequenceCarriesNoTableDetail() {
        let tables = MySQLTableListing.tables(
            from: [row("order_ids", "SEQUENCE", "leftover", "2")],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.type) == ["SEQUENCE"])
        #expect(tables.map(\.comment) == [nil])
        #expect(tables.map(\.partitionCount) == [nil])
    }

    /// Measured on MariaDB 11.4.13: `versioned_parted` is `SYSTEM VERSIONED` with PARTITION_COUNT 2,
    /// so the kind has to say both things at once or the table loses its partition rows.
    @Test("A partitioned system-versioned table keeps both facts")
    func systemVersionedPartitionedTableKeepsItsCount() {
        let tables = MySQLTableListing.tables(
            from: [row("versioned_parted", "SYSTEM VERSIONED", "", "2")],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.type) == ["SYSTEM VERSIONED PARTITIONED TABLE"])
        #expect(tables.map(\.partitionCount) == [2])
    }

    /// The count rides along, the kind does not change. An external table traded for
    /// `PARTITIONED TABLE` would pick up row editing on another catalog's data.
    @Test("A partitioned external table stays an external table")
    func externalTableKeepsItsKindWithACount() {
        let tables = MySQLTableListing.tables(
            from: [row("lake_events", "EXTERNAL TABLE", "Parquet", "6")],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.type) == ["EXTERNAL TABLE"])
        #expect(tables.map(\.comment) == ["Parquet"])
        #expect(tables.map(\.partitionCount) == [6])
    }

    @Test("A sequence is dropped where the engine does not list sequences as tables")
    func sequencesFollowTheFlavor() {
        let rows = [row("order_ids", "SEQUENCE"), row("orders", "BASE TABLE")]

        #expect(MySQLTableListing.tables(from: rows, listsSequencesAsTables: true).map(\.name) == ["order_ids", "orders"])
        #expect(MySQLTableListing.tables(from: rows, listsSequencesAsTables: false).map(\.name) == ["orders"])
    }

    @Test("Names differing only in case stay separate rows")
    func caseDistinctNames() {
        let tables = MySQLTableListing.tables(
            from: [row("Orders", "BASE TABLE"), row("orders", "BASE TABLE")],
            listsSequencesAsTables: true
        )
        #expect(Set(tables.map(\.name)) == ["Orders", "orders"])
    }

    @Test("A row with no name is skipped")
    func namelessRowSkipped() {
        #expect(MySQLTableListing.tables(from: [row(nil, "BASE TABLE")], listsSequencesAsTables: true).isEmpty)
    }

    /// Measured on 4.1.22: `SHOW TABLES` answers one column of names, and views arrived with 5.0.1.
    @Test("A one-column SHOW TABLES row lists a table")
    func showTablesRows() {
        let tables = MySQLTableListing.tables(
            from: [row("apcust"), row("acountgb"), row("apcust_send_history")],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.name) == ["acountgb", "apcust", "apcust_send_history"])
        #expect(tables.allSatisfy { $0.type == "TABLE" && $0.comment == nil && $0.partitionCount == nil })
    }

    /// Measured on 4.1.22 and 5.0.96: InnoDB appends its free space and its foreign keys to the comment
    /// in both `SHOW TABLE STATUS` and `information_schema.TABLES`.
    @Test("The InnoDB status is cut from a legacy comment, leaving what the user wrote")
    func innoDBStatusIsStripped() {
        let cases: [(stored: String, written: String?)] = [
            ("사용자 코멘트; InnoDB free: 4096 kB; (`p`) REFER `ju_mijuit_new/apcust`(`cust_no`)", "사용자 코멘트"),
            ("InnoDB free: 4096 kB", nil),
            ("InnoDB free: 4096 kB; (`cust_no`) REFER `ju_mijuit_new/apcust`(`cust_no`) ON DELETE CASCADE", nil),
        ]

        for testCase in cases {
            #expect(
                MySQLTableListing.userComment(testCase.stored, appendsInnoDBStatus: true) == testCase.written,
                "\(testCase.stored)"
            )
        }
    }

    /// 5.0 cuts the whole value at 80 characters, and a comment before 5.5 can be 60, so the cut can land
    /// inside the free space figure or the foreign key text.
    @Test("A status cut at 80 characters is still cut from the comment")
    func truncatedStatusIsStripped() {
        let cutInFigure = "Billing accounts carried over from the 2004 ledger migration; InnoDB free: 12345"
        let cutInForeignKey = "InnoDB free: 4096 kB; (`cust_no`) REFER `ju_mijuit_new/apcust`(`cust_no`) ON DEL"

        #expect(cutInFigure.count == 80)
        #expect(cutInForeignKey.count == 80)
        #expect(
            MySQLTableListing.userComment(cutInFigure, appendsInnoDBStatus: true)
                == "Billing accounts carried over from the 2004 ledger migration"
        )
        #expect(MySQLTableListing.userComment(cutInForeignKey, appendsInnoDBStatus: true) == nil)
    }

    @Test("A comment without the status, or from a server that does not append it, is left alone")
    func commentWithoutStatusIsKept() {
        let measured = "사용자 코멘트; InnoDB free: 4096 kB; (`p`) REFER `ju_mijuit_new/apcust`(`cust_no`)"

        #expect(MySQLTableListing.userComment("Audit trail", appendsInnoDBStatus: true) == "Audit trail")
        #expect(MySQLTableListing.userComment("Tracks InnoDB free: space", appendsInnoDBStatus: true) == "Tracks InnoDB free: space")
        #expect(MySQLTableListing.userComment(measured, appendsInnoDBStatus: false) == measured)
        #expect(MySQLTableListing.userComment("InnoDB free: 4096 kB", appendsInnoDBStatus: false) == "InnoDB free: 4096 kB")
        #expect(MySQLTableListing.userComment("", appendsInnoDBStatus: true) == nil)
        #expect(MySQLTableListing.userComment(nil, appendsInnoDBStatus: true) == nil)
    }

    @Test("A catalog row's comment loses the status only where the server appends it")
    func listingStripsStatusWhenAsked() {
        let rows = [
            row("apcust", "BASE TABLE", "사용자 코멘트; InnoDB free: 4096 kB; (`p`) REFER `ju_mijuit_new/apcust`(`cust_no`)", nil),
            row("acountgb", "BASE TABLE", "InnoDB free: 4096 kB", nil),
        ]

        let legacy = MySQLTableListing.tables(from: rows, listsSequencesAsTables: true, appendsInnoDBStatus: true)
        let modern = MySQLTableListing.tables(from: rows, listsSequencesAsTables: true)

        #expect(legacy.map(\.comment) == [nil, "사용자 코멘트"])
        #expect(modern.map(\.comment) == [
            "InnoDB free: 4096 kB",
            "사용자 코멘트; InnoDB free: 4096 kB; (`p`) REFER `ju_mijuit_new/apcust`(`cust_no`)",
        ])
    }
}

struct MySQLTableStatusRowTests {
    private func statusRow(name: String, comment: String = "") -> [PluginCellValue] {
        var cells = [PluginCellValue](repeating: .null, count: 18)
        cells[0] = .text(name)
        cells[1] = .text("InnoDB")
        cells[4] = .text("12")
        cells[6] = .text("16384")
        cells[8] = .text("32768")
        cells[14] = .text("euckr_korean_ci")
        cells[17] = .text(comment)
        return cells
    }

    private func name(of row: [PluginCellValue]?) -> String? {
        row?.first?.asText
    }

    /// Below 5.0.3 the read is `LIKE`, which can answer for more than one table.
    @Test("The status row is the one naming the table, never another table's")
    func rowNamingTheTable() {
        let rows = [statusRow(name: "apcust_send_history"), statusRow(name: "apcust")]

        #expect(name(of: MySQLTableStatusRow.row(named: "apcust", in: rows)) == "apcust")
        #expect(MySQLTableStatusRow.row(named: "acountgb", in: rows) == nil)
        #expect(MySQLTableStatusRow.row(named: "apcust", in: []) == nil)
    }

    @Test("A name with a LIKE wildcard picks its own row over the one the wildcard matches")
    func wildcardNeighbour() {
        let rows = [statusRow(name: "axb"), statusRow(name: "a_b")]
        #expect(name(of: MySQLTableStatusRow.row(named: "a_b", in: rows)) == "a_b")
    }

    @Test("The exact name wins, and a case variant answers only when it is the one the server matched")
    func caseVariants() {
        let both = [statusRow(name: "orders"), statusRow(name: "Orders")]

        #expect(name(of: MySQLTableStatusRow.row(named: "Orders", in: both)) == "Orders")
        #expect(name(of: MySQLTableStatusRow.row(named: "APCUST", in: [statusRow(name: "apcust")])) == "apcust")
    }

    @Test("Table Info reads the comment without the status where the server appends it")
    func metadataStripsStatus() {
        let status = statusRow(name: "apcust", comment: "사용자 코멘트; InnoDB free: 4096 kB")

        let legacy = MySQLTableStatusRow.metadata(from: status, tableName: "apcust", appendsInnoDBStatus: true)
        #expect(legacy.comment == "사용자 코멘트")
        #expect(legacy.engine == "InnoDB")
        #expect(legacy.rowCount == 12)
        #expect(legacy.totalSize == 49_152)
        #expect(legacy.collation == "euckr_korean_ci")

        let modern = MySQLTableStatusRow.metadata(from: status, tableName: "apcust")
        #expect(modern.comment == "사용자 코멘트; InnoDB free: 4096 kB")
    }
}
