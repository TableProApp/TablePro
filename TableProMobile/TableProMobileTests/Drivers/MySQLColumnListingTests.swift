import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("MySQL column listing")
struct MySQLColumnListingTests {
    private static let privileges = "select,insert,update,references"

    /// `SHOW FULL COLUMNS FROM t` verbatim from MySQL 8.4.11, with `Default` and `Extra` at 5 and 6.
    private static let mysqlShowFullColumns: [[String?]] = [
        ["id", "int", nil, "NO", "PRI", nil, "auto_increment", privileges, ""],
        ["nullable_default_null", "varchar(20)", "utf8mb4_0900_ai_ci", "YES", "", nil, "", privileges, ""],
        ["nullable_no_clause", "varchar(20)", "utf8mb4_0900_ai_ci", "YES", "", nil, "", privileges, ""],
        ["not_null_no_default", "varchar(20)", "utf8mb4_0900_ai_ci", "NO", "", nil, "", privileges, ""],
        ["s_abc", "varchar(20)", "utf8mb4_0900_ai_ci", "YES", "", "abc", "", privileges, ""],
        ["s_empty", "varchar(20)", "utf8mb4_0900_ai_ci", "YES", "", "", "", privileges, ""],
        ["s_null_text", "varchar(20)", "utf8mb4_0900_ai_ci", "YES", "", "NULL", "", privileges, ""],
        ["s_quote", "varchar(20)", "utf8mb4_0900_ai_ci", "YES", "", "it's", "", privileges, ""],
        ["n_int", "int", nil, "YES", "", "5", "", privileges, ""],
        ["n_dec", "decimal(5,2)", nil, "YES", "", "1.50", "", privileges, ""],
        ["ts", "timestamp(3)", nil, "YES", "", "CURRENT_TIMESTAMP(3)", "DEFAULT_GENERATED", privileges, ""],
        [
            "dt", "datetime", nil, "YES", "", "CURRENT_TIMESTAMP",
            "DEFAULT_GENERATED on update CURRENT_TIMESTAMP", privileges, ""
        ],
        ["s_ct_text", "varchar(20)", "utf8mb4_0900_ai_ci", "YES", "", "CURRENT_TIMESTAMP", "", privileges, ""],
        ["e_uuid", "varchar(36)", "utf8mb4_0900_ai_ci", "YES", "", "uuid()", "DEFAULT_GENERATED", privileges, ""],
        [
            "e_concat", "varchar(20)", "utf8mb4_0900_ai_ci", "YES", "", #"concat(_utf8mb4\'a\',_utf8mb4\'b\')"#,
            "DEFAULT_GENERATED", privileges, ""
        ],
        ["s_uuid_text", "varchar(36)", "utf8mb4_0900_ai_ci", "YES", "", "uuid()", "", privileges, ""],
        ["b", "bit(1)", nil, "YES", "", "b'1'", "", privileges, ""],
        ["bin", "varbinary(4)", nil, "YES", "", "0x6162", "", privileges, ""],
        ["g", "int", nil, "YES", "", nil, "VIRTUAL GENERATED", privileges, ""],
        ["txt", "text", "utf8mb4_0900_ai_ci", "YES", "", nil, "", privileges, ""]
    ]

    /// `SHOW FULL COLUMNS FROM t` verbatim from MariaDB 13.0.2, for the same table. Every literal comes
    /// back unquoted and no expression is marked, so `e_uuid` and `s_uuid_text` read the same here.
    private static let mariaDBShowFullColumns: [[String?]] = [
        ["id", "int(11)", nil, "NO", "PRI", nil, "auto_increment", privileges, ""],
        ["nullable_default_null", "varchar(20)", "utf8mb4_general_ci", "YES", "", nil, "", privileges, ""],
        ["nullable_no_clause", "varchar(20)", "utf8mb4_general_ci", "YES", "", nil, "", privileges, ""],
        ["not_null_no_default", "varchar(20)", "utf8mb4_general_ci", "NO", "", nil, "", privileges, ""],
        ["s_abc", "varchar(20)", "utf8mb4_general_ci", "YES", "", "abc", "", privileges, ""],
        ["s_empty", "varchar(20)", "utf8mb4_general_ci", "YES", "", "", "", privileges, ""],
        ["s_null_text", "varchar(20)", "utf8mb4_general_ci", "YES", "", "NULL", "", privileges, ""],
        ["s_quote", "varchar(20)", "utf8mb4_general_ci", "YES", "", "it's", "", privileges, ""],
        ["n_int", "int(11)", nil, "YES", "", "5", "", privileges, ""],
        ["n_dec", "decimal(5,2)", nil, "YES", "", "1.50", "", privileges, ""],
        ["ts", "timestamp(3)", nil, "YES", "", "current_timestamp(3)", "", privileges, ""],
        [
            "dt", "datetime", nil, "YES", "", "current_timestamp()", "on update current_timestamp()",
            privileges, ""
        ],
        ["s_ct_text", "varchar(20)", "utf8mb4_general_ci", "YES", "", "CURRENT_TIMESTAMP", "", privileges, ""],
        ["e_uuid", "varchar(36)", "utf8mb4_general_ci", "YES", "", "uuid()", "", privileges, ""],
        ["e_concat", "varchar(20)", "utf8mb4_general_ci", "YES", "", "concat('a','b')", "", privileges, ""],
        ["s_uuid_text", "varchar(36)", "utf8mb4_general_ci", "YES", "", "uuid()", "", privileges, ""],
        ["b", "bit(1)", nil, "YES", "", "b'1'", "", privileges, ""],
        ["bin", "varbinary(4)", nil, "YES", "", "x'6162'", "", privileges, ""],
        ["g", "int(11)", nil, "YES", "", nil, "VIRTUAL GENERATED", privileges, ""],
        ["txt", "text", "utf8mb4_general_ci", "YES", "", nil, "", privileges, ""]
    ]

    /// `SELECT COLUMN_NAME, COLUMN_DEFAULT FROM INFORMATION_SCHEMA.COLUMNS` verbatim from MariaDB 13.0.2,
    /// where literals are quoted, expressions are bare and `DEFAULT NULL` is the unquoted text `NULL`.
    private static let mariaDBCatalogColumns: [[String?]] = [
        ["id", nil],
        ["nullable_default_null", "NULL"],
        ["nullable_no_clause", "NULL"],
        ["not_null_no_default", nil],
        ["s_abc", "'abc'"],
        ["s_empty", "''"],
        ["s_null_text", "'NULL'"],
        ["s_quote", "'it''s'"],
        ["n_int", "5"],
        ["n_dec", "1.50"],
        ["ts", "current_timestamp(3)"],
        ["dt", "current_timestamp()"],
        ["s_ct_text", "'CURRENT_TIMESTAMP'"],
        ["e_uuid", "uuid()"],
        ["e_concat", "concat('a','b')"],
        ["s_uuid_text", "'uuid()'"],
        ["b", "b'1'"],
        ["bin", "x'6162'"],
        ["g", "NULL"],
        ["txt", "NULL"]
    ]

    private func defaults(of columns: [ColumnInfo]) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0.defaultValue) })
    }

    private func expectDefaults(_ columns: [ColumnInfo], _ expected: [(name: String, sql: String?)]) {
        let byName = defaults(of: columns)
        for column in expected {
            #expect(byName[column.name] == .some(column.sql), "\(column.name)")
        }
    }

    @Test("MySQL defaults read as the SQL that recreates them, DEFAULT NULL included")
    func mysqlDefaultsReadAsSQL() {
        let source = MySQLColumnListing.defaultSource(flavor: .mysql, banner: "8.4.11")
        #expect(source == .showFullColumns)
        #expect(MySQLColumnListing.catalogDefaultsQuery(table: "t", source: source) == nil)

        let columns = MySQLColumnListing.columns(
            fromShowFullColumns: Self.mysqlShowFullColumns, catalogDefaults: [:], source: source
        )
        #expect(columns.map(\.name) == Self.mysqlShowFullColumns.compactMap { $0[0] })
        expectDefaults(columns, [
            ("id", nil),
            ("nullable_default_null", "NULL"),
            ("nullable_no_clause", "NULL"),
            ("not_null_no_default", nil),
            ("s_abc", "'abc'"),
            ("s_empty", "''"),
            ("s_null_text", "'NULL'"),
            ("s_quote", "'it''s'"),
            ("n_int", "5"),
            ("n_dec", "1.50"),
            ("ts", "CURRENT_TIMESTAMP(3)"),
            ("dt", "CURRENT_TIMESTAMP"),
            ("s_ct_text", "'CURRENT_TIMESTAMP'"),
            ("e_uuid", "(uuid())"),
            ("e_concat", "(concat(_utf8mb4'a',_utf8mb4'b'))"),
            ("s_uuid_text", "'uuid()'"),
            ("b", "b'1'"),
            ("bin", "0x6162"),
            ("g", nil),
            ("txt", "NULL")
        ])
    }

    @Test("MariaDB defaults come from its quoted catalog, which tells an expression from a string")
    func mariaDBDefaultsComeFromTheQuotedCatalog() {
        let source = MySQLColumnListing.defaultSource(flavor: .mariadb, banner: "13.0.2-MariaDB")
        #expect(source == .quotedCatalog)

        let catalog = MySQLColumnListing.catalogDefaults(fromRows: Self.mariaDBCatalogColumns, source: source)
        let columns = MySQLColumnListing.columns(
            fromShowFullColumns: Self.mariaDBShowFullColumns, catalogDefaults: catalog, source: source
        )
        expectDefaults(columns, [
            ("id", nil),
            ("nullable_default_null", "NULL"),
            ("nullable_no_clause", "NULL"),
            ("not_null_no_default", nil),
            ("s_abc", "'abc'"),
            ("s_empty", "''"),
            ("s_null_text", "'NULL'"),
            ("s_quote", "'it''s'"),
            ("n_int", "5"),
            ("n_dec", "1.50"),
            ("ts", "current_timestamp(3)"),
            ("dt", "current_timestamp()"),
            ("s_ct_text", "'CURRENT_TIMESTAMP'"),
            ("e_uuid", "uuid()"),
            ("e_concat", "concat('a','b')"),
            ("s_uuid_text", "'uuid()'"),
            ("b", "b'1'"),
            ("bin", "x'6162'"),
            ("g", nil),
            ("txt", "NULL")
        ])
    }

    /// A catalog that refuses leaves `SHOW FULL COLUMNS` as the only source, which still states every
    /// literal and `DEFAULT NULL` right. Its expressions read as strings; the Mac app settles those from
    /// `SHOW CREATE TABLE`, which this does not read.
    @Test("A MariaDB whose catalog refuses still reads its literals and DEFAULT NULL")
    func mariaDBWithoutTheCatalogReadsLiterals() {
        let columns = MySQLColumnListing.columns(
            fromShowFullColumns: Self.mariaDBShowFullColumns, catalogDefaults: [:], source: .quotedCatalog
        )
        expectDefaults(columns, [
            ("id", nil),
            ("nullable_default_null", "NULL"),
            ("not_null_no_default", nil),
            ("s_abc", "'abc'"),
            ("s_empty", "''"),
            ("s_null_text", "'NULL'"),
            ("s_quote", "'it''s'"),
            ("n_int", "5"),
            ("ts", "current_timestamp(3)"),
            ("bin", "x'6162'"),
            ("g", nil),
            ("txt", "NULL")
        ])
    }

    @Test("Each server reads its defaults where the Mac app reads them")
    func defaultSourceFollowsTheServer() {
        let cases: [(flavor: MySQLServerFlavor, banner: String, source: MySQLColumnListing.DefaultSource)] = [
            (.mysql, "8.4.11", .showFullColumns),
            (.mariadb, "13.0.2-MariaDB", .quotedCatalog),
            (.mariadb, "10.2.7-MariaDB", .quotedCatalog),
            (.mariadb, "10.2.6-MariaDB", .showFullColumns),
            (.tidb(version: nil), "8.0.11-TiDB-v7.5.0", .showFullColumns),
            (.oceanbase(version: nil), "5.7.25", .oceanBaseCatalog),
            (.databend, "8.0.90-v1.2.3-nightly", .asReported)
        ]
        for testCase in cases {
            #expect(
                MySQLColumnListing.defaultSource(flavor: testCase.flavor, banner: testCase.banner) == testCase.source,
                "\(testCase.banner)"
            )
        }
    }

    @Test("A MySQL connection that reaches a MariaDB reads the quoted catalog too")
    func mysqlConnectionToMariaDB() {
        let flavor = MySQLDriver.serverFlavor(for: .mysql, banner: "13.0.2-MariaDB")
        #expect(MySQLColumnListing.defaultSource(flavor: flavor, banner: "13.0.2-MariaDB") == .quotedCatalog)
    }

    @Test("The catalog read names the session's database and escapes the table name")
    func catalogQueryReadsTheSessionDatabase() throws {
        let query = try #require(MySQLColumnListing.catalogDefaultsQuery(table: #"o'b\x"#, source: .quotedCatalog))
        #expect(query.contains("TABLE_SCHEMA = DATABASE()"))
        #expect(query.contains(#"TABLE_NAME = 'o''b\\x'"#))
        #expect(MySQLColumnListing.catalogDefaultsQuery(table: "t", source: .oceanBaseCatalog) != nil)
        #expect(MySQLColumnListing.catalogDefaultsQuery(table: "t", source: .asReported) == nil)
    }

    /// OceanBase's catalog drops the precision `CURRENT_TIMESTAMP(3)` was declared with, reports a
    /// binary default as the text it holds, and answers a view right where `SHOW FULL COLUMNS` gives
    /// the text `NULL` for every default. The shapes are OceanBase CE 4.4.2.1's.
    @Test("OceanBase defaults read from its catalog with the Mac app's OceanBase rules")
    func oceanBaseDefaults() {
        let show: [[String?]] = [
            ["ts", "timestamp(3)", nil, "YES", "", "CURRENT_TIMESTAMP", "", Self.privileges, ""],
            ["bin", "varbinary(4)", nil, "YES", "", "ab", "", Self.privileges, ""],
            ["s", "varchar(10)", "utf8mb4_general_ci", "YES", "", "abc", "", Self.privileges, ""],
            ["v", "varchar(10)", "utf8mb4_general_ci", "YES", "", "NULL", "", Self.privileges, ""]
        ]
        let catalogRows: [[String?]] = [["ts", "CURRENT_TIMESTAMP"], ["bin", "ab"], ["s", "abc"], ["v", nil]]
        let source = MySQLColumnListing.defaultSource(flavor: .oceanbase(version: nil), banner: "5.7.25")
        let catalog = MySQLColumnListing.catalogDefaults(fromRows: catalogRows, source: source)
        let columns = MySQLColumnListing.columns(fromShowFullColumns: show, catalogDefaults: catalog, source: source)
        expectDefaults(columns, [
            ("ts", "CURRENT_TIMESTAMP(3)"),
            ("bin", "'ab'"),
            ("s", "'abc'"),
            ("v", "NULL")
        ])
    }

    @Test("A Databend default is shown as the server states it")
    func databendDefaultsAreUnchanged() {
        let show: [[String?]] = [["a", "VARCHAR", nil, "YES", "", "'x'", "", "", ""]]
        let columns = MySQLColumnListing.columns(fromShowFullColumns: show, catalogDefaults: [:], source: .asReported)
        #expect(columns.first?.defaultValue == "'x'")
    }

    @Test("The generated and auto-increment flags still come from Extra")
    func extraFlagsSurvive() {
        let columns = MySQLColumnListing.columns(
            fromShowFullColumns: Self.mysqlShowFullColumns, catalogDefaults: [:], source: .showFullColumns
        )
        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
        #expect(byName["id"]?.isAutoIncrement == true)
        #expect(byName["id"]?.isPrimaryKey == true)
        #expect(byName["g"]?.isGenerated == true)
        #expect(byName["e_uuid"]?.isGenerated == false)
        #expect(byName["not_null_no_default"]?.isNullable == false)
        #expect(columns.map(\.ordinalPosition) == Array(0..<Self.mysqlShowFullColumns.count))
    }
}
