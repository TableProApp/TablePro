import Foundation
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

@Suite("PostgreSQL catalog reads on iOS")
struct PostgreSQLCatalogQueryTests {
    private static let allCatalogs = PostgreSQLDriver.presence(
        probedRows: [["pg_matviews"], ["pg_foreign_table"], ["pg_sequences"]]
    )

    private static let indexRowsFromPostgreSQL17: [[String?]] = [
        ["t", "t_pkey", "{id}", "t", "t", "btree", nil, "{}", "{}"],
        ["t", "t_brin", "{id}", "f", "f", "brin", nil, "{}", "{}"],
        ["t", "t_expr_only", "{lower(email)}", "f", "f", "btree", nil, "{lower(email)}", "{}"],
        ["t", "t_gin", "{tags}", "f", "f", "gin", nil, "{}", "{}"],
        ["t", "t_hash", "{email}", "f", "f", "hash", nil, "{}", "{}"],
        ["t", "t_include", "{a}", "f", "f", "btree", nil, "{}", "{b}"],
        ["t", "t_mixed", "{tenant_id,lower(email)}", "f", "f", "btree", nil, "{lower(email)}", "{}"],
        ["t", "t_order", "{b,a}", "f", "f", "btree", nil, "{}", "{}"],
        ["t", "t_partial", "{a}", "t", "f", "btree", "(a > 0)", "{}", "{}"]
    ]

    @Test("a materialized view is listed as one")
    func materializedViewKind() {
        let rows: [[String?]] = [
            ["mv", "MATERIALIZED VIEW", nil, nil],
            ["t", "BASE TABLE", nil, nil],
            ["v", "VIEW", nil, nil]
        ]

        let tables = PostgreSQLDriver.tables(fromRows: rows, databaseType: .postgresql)

        #expect(tables.map(\.name) == ["mv", "t", "v"])
        #expect(tables.map(\.type) == [.materializedView, .table, .view])
        #expect(tables.first?.type.listSection == .views)
    }

    @Test("the listing reads pg_matviews and pg_foreign_table only when the probe found them")
    func optionalCatalogsFollowTheProbe() {
        let withCatalogs = PostgreSQLDriver.tablesQuery(
            schema: "public", databaseType: .postgresql, presence: Self.allCatalogs
        )
        let withoutCatalogs = PostgreSQLDriver.tablesQuery(
            schema: "public",
            databaseType: .postgresql,
            presence: PostgreSQLDriver.presence(probedRows: [["pg_sequences"]])
        )

        #expect(withCatalogs.contains("FROM pg_matviews m"))
        #expect(withCatalogs.contains("FROM pg_foreign_table ft"))
        #expect(!withoutCatalogs.contains("pg_matviews"))
        #expect(!withoutCatalogs.contains("pg_foreign_table"))
    }

    @Test("a failed catalog probe lists without the optional catalogs")
    func failedProbeMeansAbsent() {
        let presence = PostgreSQLDriver.presence(probedRows: nil)

        #expect(!presence.hasMaterializedViews)
        #expect(!presence.hasForeignTables)
        let query = PostgreSQLDriver.tablesQuery(schema: "public", databaseType: .postgresql, presence: presence)
        #expect(!query.contains("pg_matviews"))
        #expect(!query.contains("pg_foreign_table"))
        #expect(query.contains("FROM information_schema.tables t"))
    }

    @Test("the iOS listing reads no comments and keeps partitions listed flat")
    func noCommentsOrPartitionAwareness() {
        let query = PostgreSQLDriver.tablesQuery(schema: "public", databaseType: .postgresql, presence: Self.allCatalogs)

        #expect(!query.contains("obj_description"))
        #expect(!query.contains("pg_inherits"))
    }

    @Test("Redshift keeps the listing the macOS Redshift driver runs")
    func redshiftListing() {
        let query = PostgreSQLDriver.tablesQuery(schema: "public", databaseType: .redshift, presence: Self.allCatalogs)
        let tables = PostgreSQLDriver.tables(
            fromRows: [["orders", "BASE TABLE"], ["recent", "VIEW"]],
            databaseType: .redshift
        )

        #expect(query == RedshiftTableCatalog.listingQuery(schema: "public"))
        #expect(!query.contains("pg_matviews"))
        #expect(tables.map(\.type) == [.table, .view])
    }

    @Test("index rows read from PostgreSQL 17.11 keep expression keys, key order, INCLUDE columns, predicates and methods")
    func indexRowsDecode() throws {
        let indexes = PostgreSQLDriver.indexes(fromRows: Self.indexRowsFromPostgreSQL17, databaseType: .postgresql)
        let byName = Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, $0) })

        #expect(indexes.count == 9)
        let primary = try #require(byName["t_pkey"])
        let include = try #require(byName["t_include"])
        let partial = try #require(byName["t_partial"])
        #expect(primary.isPrimary)
        #expect(byName["t_expr_only"]?.columns == ["lower(email)"])
        #expect(byName["t_mixed"]?.columns == ["tenant_id", "lower(email)"])
        #expect(include.columns == ["a"])
        #expect(include.includedColumns == ["b"])
        #expect(byName["t_order"]?.columns == ["b", "a"])
        #expect(partial.whereClause == "(a > 0)")
        #expect(partial.isUnique)
        #expect(byName["t_gin"]?.type == "GIN")
        #expect(byName["t_hash"]?.type == "HASH")
        #expect(byName["t_brin"]?.type == "BRIN")
        #expect(byName["t_order"]?.type == "BTREE")
    }

    @Test("INCLUDE columns are told apart by indnkeyatts from PostgreSQL 11, and on a server that reports no version")
    func indexKeyCountFollowsTheServerVersion() {
        func query(_ version: Int32) -> String {
            PostgreSQLDriver.indexesQuery(
                schema: "public", table: "t", databaseType: .postgresql, serverVersionNumber: version
            )
        }

        #expect(query(170_011).contains("generate_series(1, ix.indnkeyatts)"))
        #expect(query(110_000).contains("generate_series(1, ix.indnkeyatts)"))
        #expect(query(0).contains("generate_series(1, ix.indnkeyatts)"))
        #expect(!query(100_000).contains("indnkeyatts"))
        #expect(query(100_000).contains("generate_series(1, ix.indnatts)"))
    }

    @Test("the index read is scoped to the schema and table, quoted")
    func indexQueryQuotes() {
        let query = PostgreSQLDriver.indexesQuery(
            schema: "o'brien", table: "it's", databaseType: .postgresql, serverVersionNumber: 170_011
        )

        #expect(query.contains("n.nspname = 'o''brien'"))
        #expect(query.contains("t.relname = 'it''s'"))
    }

    @Test("a Redshift server reads its distribution and sort keys and never the pg_index read")
    func redshiftKeys() {
        let query = PostgreSQLDriver.indexesQuery(
            schema: "public", table: "orders", databaseType: .redshift, serverVersionNumber: 80_002
        )
        let keys = PostgreSQLDriver.indexes(
            fromRows: [["id", "integer", "true", "1"], ["created_at", "timestamp", "false", "2"]],
            databaseType: .redshift
        )

        #expect(query == RedshiftTableCatalog.keysQuery(schema: "public", table: "orders"))
        #expect(!query.contains("generate_series"))
        #expect(!query.contains("pg_index"))
        #expect(keys.map(\.name) == ["DISTKEY", "SORTKEY"])
        #expect(keys.last?.columns == ["id", "created_at"])
    }

    @Test("the column read adds the materialized view arm only when asked, inside a derived table")
    func materializedViewArm() {
        let withArm = PostgreSQLDriver.columnsQuery(
            schema: "public",
            table: "mv",
            shape: PostgreSQLColumnReadShape(includesIdentityColumns: true, includesMaterializedViews: true)
        )
        let withoutArm = PostgreSQLDriver.columnsQuery(
            schema: "public",
            table: "mv",
            shape: PostgreSQLColumnReadShape(includesIdentityColumns: true, includesMaterializedViews: false)
        )

        #expect(withArm.contains("mvc.relkind = 'm'"))
        #expect(withArm.contains("AND mvc.relname = 'mv'"))
        #expect(!withoutArm.contains("relkind = 'm'"))
        #expect(Self.arms(of: withArm).count == 2)
        #expect(Self.arms(of: withoutArm).count == 1)
        #expect(withArm.hasSuffix(") cols\nORDER BY cols.ordinal_position"))
    }

    @Test(
        "every arm projects the same columns in the same order, and ordinal_position stays out of the result",
        arguments: [true, false]
    )
    func armsAgree(includesIdentityColumns: Bool) {
        let query = PostgreSQLDriver.columnsQuery(
            schema: "public",
            table: "mv",
            shape: PostgreSQLColumnReadShape(
                includesIdentityColumns: includesIdentityColumns,
                includesMaterializedViews: true
            )
        )
        let identity = includesIdentityColumns ? ["is_identity", "is_generated"] : []
        let result = ["column_name", "data_type", "is_nullable", "column_default", "character_maximum_length", "is_pk"]
            + identity

        for arm in Self.arms(of: query) {
            #expect(Self.aliases(in: arm) == result + ["ordinal_position"])
        }
        #expect(Self.outerProjection(of: query) == result.map { "cols.\($0)" })
    }

    @Test("the column read quotes the schema and table in both arms")
    func columnQueryQuotes() {
        let query = PostgreSQLDriver.columnsQuery(
            schema: "o'brien",
            table: "it's",
            shape: PostgreSQLColumnReadShape(includesIdentityColumns: false, includesMaterializedViews: true)
        )

        #expect(query.contains("c.table_schema = 'o''brien' AND c.table_name = 'it''s'"))
        #expect(query.contains("mvn.nspname = 'o''brien'"))
        #expect(query.contains("AND mvc.relname = 'it''s'"))
    }

    @Test("materialized view rows decode like table rows")
    func materializedViewColumnRows() {
        let columns = PostgreSQLDriver.columns(fromRows: [
            ["id", "integer", "YES", nil, nil, "NO", "NO", "NEVER"],
            ["email", "text", "NO", nil, nil, "NO", "NO", "NEVER"],
            ["v", "character varying", "YES", nil, "50", "NO", "NO", "NEVER"]
        ])

        #expect(columns.map(\.name) == ["id", "email", "v"])
        #expect(columns.map(\.isNullable) == [true, false, true])
        #expect(columns.map(\.characterMaxLength) == [nil, nil, 50])
        #expect(columns.allSatisfy { !$0.isPrimaryKey && !$0.isAutoIncrement && !$0.isGenerated })
    }

    @Test("Redshift routes to the PostgreSQL driver with its own type")
    func redshiftRoutesWithItsType() throws {
        let redshift = DatabaseConnection(name: "r", type: .redshift, host: "127.0.0.1", port: 5_439)
        let postgres = DatabaseConnection(name: "p", type: .postgresql, host: "127.0.0.1", port: 5_432)

        let redshiftDriver = try #require(
            try IOSDriverFactory().createDriver(for: redshift, password: nil) as? PostgreSQLDriver
        )
        let postgresDriver = try #require(
            try IOSDriverFactory().createDriver(for: postgres, password: nil) as? PostgreSQLDriver
        )

        #expect(redshiftDriver.databaseType == .redshift)
        #expect(postgresDriver.databaseType == .postgresql)
    }

    private static func arms(of query: String) -> [String] {
        guard let start = query.range(of: "FROM (\n"), let end = query.range(of: "\n) cols") else { return [] }
        return query[start.upperBound..<end.lowerBound].components(separatedBy: "\nUNION ALL\n")
    }

    private static func aliases(in arm: String) -> [String] {
        let projection = arm.components(separatedBy: "\nFROM ").first ?? ""
        let pattern = /\sAS ([a-z_]+)/
        return projection.matches(of: pattern).map { String($0.output.1) }
    }

    private static func outerProjection(of query: String) -> [String] {
        let projection = query.components(separatedBy: "\nFROM (\n").first ?? ""
        return projection
            .replacingOccurrences(of: "SELECT", with: "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

@Suite("PostgreSQL column read fallbacks on iOS")
struct PostgreSQLColumnReadSupportTests {
    private typealias Shape = PostgreSQLColumnReadShape

    @Test("without materialized views the read tries identity columns, then none")
    func withoutMaterializedViews() {
        let attempts = PostgreSQLColumnReadSupport().attempts(materializedViewsPresent: false)

        #expect(attempts == [
            Shape(includesIdentityColumns: true, includesMaterializedViews: false),
            Shape(includesIdentityColumns: false, includesMaterializedViews: false)
        ])
    }

    @Test("with materialized views the identity columns are dropped before the materialized view arm")
    func withMaterializedViews() {
        let attempts = PostgreSQLColumnReadSupport().attempts(materializedViewsPresent: true)

        #expect(attempts == [
            Shape(includesIdentityColumns: true, includesMaterializedViews: true),
            Shape(includesIdentityColumns: false, includesMaterializedViews: true),
            Shape(includesIdentityColumns: true, includesMaterializedViews: false),
            Shape(includesIdentityColumns: false, includesMaterializedViews: false)
        ])
    }

    @Test("a read that only worked without the materialized view arm keeps the identity columns")
    func materializedViewArmFailureKeepsIdentity() {
        let learned = PostgreSQLColumnReadSupport().learning(
            from: Shape(includesIdentityColumns: true, includesMaterializedViews: false),
            materializedViewsPresent: true
        )

        #expect(learned.identityColumns == true)
        #expect(learned.materializedViewColumns == false)
        #expect(learned.attempts(materializedViewsPresent: true) == [
            Shape(includesIdentityColumns: true, includesMaterializedViews: false),
            Shape(includesIdentityColumns: false, includesMaterializedViews: false)
        ])
    }

    @Test("a read that only worked without identity columns keeps the materialized view arm")
    func identityFailureKeepsMaterializedViews() {
        let learned = PostgreSQLColumnReadSupport().learning(
            from: Shape(includesIdentityColumns: false, includesMaterializedViews: true),
            materializedViewsPresent: true
        )

        #expect(learned.identityColumns == false)
        #expect(learned.materializedViewColumns == true)
        #expect(learned.attempts(materializedViewsPresent: true) == [
            Shape(includesIdentityColumns: false, includesMaterializedViews: true),
            Shape(includesIdentityColumns: false, includesMaterializedViews: false)
        ])
    }

    @Test("a server without materialized views learns nothing about the arm")
    func noMaterializedViewsLearnsNothingAboutTheArm() {
        let learned = PostgreSQLColumnReadSupport().learning(
            from: Shape(includesIdentityColumns: true, includesMaterializedViews: false),
            materializedViewsPresent: false
        )

        #expect(learned.identityColumns == true)
        #expect(learned.materializedViewColumns == nil)
    }
}
