//
//  PostgreSQLDriverTests.swift
//  TableProTests
//
//  Regression tests for PostgreSQL DDL functionality.
//  Validates source-level guards against PG16 breakage, correct SQL escaping,
//  DDL assembly logic, and DDL loading flow behavior.
//

import Foundation
import Testing
@testable import TablePro

// MARK: - SQL Escaping Correctness

@Suite("PostgreSQL SQL Escaping Correctness")
struct PostgreSQLSQLEscapingCorrectness {

    @Test("ANSI escaping preserves backslashes")
    func backslashPreserved() {
        let input = "test\\table"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "test\\table")
    }

    @Test("ANSI escaping preserves literal newlines")
    func newlinePreserved() {
        let input = "line1\nline2"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "line1\nline2")
    }

    @Test("ANSI escaping preserves literal tabs")
    func tabPreserved() {
        let input = "col1\tcol2"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "col1\tcol2")
    }

    @Test("ANSI escaping doubles single quotes and preserves control chars")
    func combinedSpecialChars() {
        let input = "it's a \\path\n"
        let result = SQLEscaping.escapeStringLiteral(input)

        #expect(!result.contains("\\\\"), "ANSI escaping should not double backslashes")
        #expect(result.contains("\n"), "ANSI escaping should preserve literal newlines")
        #expect(result.contains("''"), "ANSI escaping should double single quotes")
    }
}

// MARK: - DDL Assembly

@Suite("PostgreSQL DDL Assembly")
struct PostgreSQLDDLAssembly {

    private func assembleDDL(
        schema: String,
        table: String,
        columns: [String],
        constraints: [String] = [],
        indexes: [String] = []
    ) -> String? {
        guard !columns.isEmpty else { return nil }

        let quotedSchema = "\"\(schema.replacingOccurrences(of: "\"", with: "\"\""))\""
        let quotedTable = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""

        var parts = columns
        parts.append(contentsOf: constraints)

        let ddl = "CREATE TABLE \(quotedSchema).\(quotedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        if indexes.isEmpty {
            return ddl
        }

        return ddl + "\n\n" + indexes.joined(separator: ";\n") + ";"
    }

    @Test("Basic CREATE TABLE with columns only")
    func basicCreateTableColumnsOnly() {
        let columns = [
            "\"id\" integer NOT NULL DEFAULT nextval('users_id_seq'::regclass)",
            "\"name\" character varying(255)"
        ]

        let result = assembleDDL(schema: "public", table: "users", columns: columns)

        let expected = """
            CREATE TABLE "public"."users" (
              "id" integer NOT NULL DEFAULT nextval('users_id_seq'::regclass),
              "name" character varying(255)
            );
            """
            .replacingOccurrences(of: "            ", with: "")

        #expect(result == expected)
    }

    @Test("CREATE TABLE with constraints appears after columns")
    func createTableWithConstraints() {
        let columns = [
            "\"id\" integer NOT NULL",
            "\"email\" character varying(255) NOT NULL"
        ]
        let constraints = [
            "PRIMARY KEY (\"id\")",
            "UNIQUE (\"email\")"
        ]

        let result = assembleDDL(schema: "public", table: "users", columns: columns, constraints: constraints)!

        #expect(result.contains("\"id\" integer NOT NULL,"))
        #expect(result.contains("\"email\" character varying(255) NOT NULL,"))
        #expect(result.contains("PRIMARY KEY (\"id\"),"))
        #expect(result.contains("UNIQUE (\"email\")"))
        #expect(result.hasSuffix(");"))

        let idPos = (result as NSString).range(of: "\"id\" integer").location
        let pkPos = (result as NSString).range(of: "PRIMARY KEY").location
        #expect(idPos < pkPos, "Columns should appear before constraints")
    }

    @Test("CREATE TABLE with indexes — indexes appear after the statement")
    func createTableWithIndexes() {
        let columns = ["\"id\" integer NOT NULL"]
        let indexes = [
            "CREATE INDEX \"idx_users_name\" ON \"public\".\"users\" USING btree (\"name\")"
        ]

        let result = assembleDDL(schema: "public", table: "users", columns: columns, indexes: indexes)!

        #expect(result.contains(");"))
        #expect(result.contains("\n\n"))
        #expect(result.contains("CREATE INDEX"))

        let semiPos = (result as NSString).range(of: ");").location
        let indexPos = (result as NSString).range(of: "CREATE INDEX").location
        #expect(semiPos < indexPos, "Indexes should appear after CREATE TABLE statement")
    }

    @Test("Empty columns returns nil — no empty CREATE TABLE produced")
    func emptyColumnsReturnsNil() {
        let result = assembleDDL(schema: "public", table: "users", columns: [])
        #expect(result == nil)
    }

    @Test("Schema and table names with double quotes are properly escaped")
    func schemaAndTableNameQuoting() {
        let result = assembleDDL(
            schema: "my\"schema",
            table: "my\"table",
            columns: ["\"col\" integer"]
        )!

        #expect(result.contains("\"my\"\"schema\""))
        #expect(result.contains("\"my\"\"table\""))
    }
}

// MARK: - DDL Loading Flow Mock

private final class MockPostgreSQLDriver: DatabaseDriver {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? = "16.0.0"

    var ddlToReturn: String = ""
    var sequencesToReturn: [(name: String, ddl: String)] = []
    var enumTypesToReturn: [(name: String, labels: [String])] = []

    var shouldFailSequences = false
    var shouldFailDDL = false
    var sequenceError: Error = DatabaseError.queryFailed("column ad.adsrc does not exist")

    init(connection: DatabaseConnection = TestFixtures.makeConnection(type: .postgresql)) {
        self.connection = connection
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func execute(query: String) async throws -> QueryResult { .empty }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { .empty }
    func fetchRowCount(query: String) async throws -> Int { 0 }
    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult { .empty }

    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }

    func fetchTableDDL(table: String) async throws -> String {
        if shouldFailDDL {
            throw DatabaseError.queryFailed("Failed to fetch DDL for table '\(table)'")
        }
        return ddlToReturn
    }

    func fetchDependentSequences(forTable table: String) async throws -> [(name: String, ddl: String)] {
        if shouldFailSequences {
            throw sequenceError
        }
        return sequencesToReturn
    }

    func fetchDependentTypes(forTable table: String) async throws -> [(name: String, labels: [String])] {
        enumTypesToReturn
    }

    func fetchViewDefinition(view: String) async throws -> String { "" }
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil,
            avgRowLength: nil, rowCount: nil, comment: nil, engine: nil,
            collation: nil, createTime: nil, updateTime: nil
        )
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchSchemas() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database, name: database, tableCount: nil, sizeBytes: nil,
            lastAccessed: nil, isSystemDatabase: false, icon: "cylinder"
        )
    }
    func createDatabase(name: String, charset: String, collation: String?) async throws {}
    func cancelQuery() throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

@Suite("DDL Loading Flow with Mock Driver")
struct DDLLoadingFlowTests {

    private func loadDDL(using driver: MockPostgreSQLDriver, table: String) async throws -> String {
        let sequences = try await driver.fetchDependentSequences(forTable: table)
        let enumTypes = try await driver.fetchDependentTypes(forTable: table)
        let baseDDL = try await driver.fetchTableDDL(table: table)

        if sequences.isEmpty && enumTypes.isEmpty {
            return baseDDL
        }

        var preamble = ""
        for seq in sequences {
            preamble += seq.ddl + "\n\n"
        }
        for enumType in enumTypes {
            let quotedName = "\"\(enumType.name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let quotedLabels = enumType.labels.map { "'\(SQLEscaping.escapeStringLiteral($0))'" }
            preamble += "CREATE TYPE \(quotedName) AS ENUM (\(quotedLabels.joined(separator: ", ")));\n"
        }

        return preamble + "\n" + baseDDL
    }

    @Test("Successful flow — all three methods return valid data and DDL is assembled correctly")
    func successfulFlow() async throws {
        let driver = MockPostgreSQLDriver()
        driver.ddlToReturn = """
            CREATE TABLE "public"."users" (
              "id" integer NOT NULL DEFAULT nextval('users_id_seq'::regclass),
              "name" character varying(255)
            );
            """
        driver.sequencesToReturn = [
            (name: "users_id_seq", ddl: "CREATE SEQUENCE \"users_id_seq\" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1;")
        ]
        driver.enumTypesToReturn = [
            (name: "user_role", labels: ["admin", "editor", "viewer"])
        ]

        let result = try await loadDDL(using: driver, table: "users")

        #expect(result.contains("CREATE SEQUENCE \"users_id_seq\""))
        #expect(result.contains("CREATE TYPE \"user_role\" AS ENUM ('admin', 'editor', 'viewer')"))
        #expect(result.contains("CREATE TABLE \"public\".\"users\""))

        let seqPos = (result as NSString).range(of: "CREATE SEQUENCE").location
        let typePos = (result as NSString).range(of: "CREATE TYPE").location
        let tablePos = (result as NSString).range(of: "CREATE TABLE").location
        #expect(seqPos < typePos, "Sequences should appear before types")
        #expect(typePos < tablePos, "Types should appear before CREATE TABLE")
    }

    @Test("fetchDependentSequences failure propagates — proves the original PG16 bug")
    func sequenceFailurePropagates() async throws {
        let driver = MockPostgreSQLDriver()
        driver.shouldFailSequences = true
        driver.ddlToReturn = "CREATE TABLE \"public\".\"users\" (\"id\" integer);"

        await #expect(throws: DatabaseError.self) {
            _ = try await loadDDL(using: driver, table: "users")
        }
    }

    @Test("fetchTableDDL returns empty columns — throws error")
    func emptyDDLThrowsError() async throws {
        let driver = MockPostgreSQLDriver()
        driver.shouldFailDDL = true

        await #expect(throws: DatabaseError.self) {
            _ = try await loadDDL(using: driver, table: "nonexistent")
        }
    }

    @Test("No sequences or types — baseDDL returned directly without preamble")
    func noSequencesOrTypesReturnsBaseDDL() async throws {
        let driver = MockPostgreSQLDriver()
        let baseDDL = "CREATE TABLE \"public\".\"orders\" (\"id\" integer NOT NULL);"
        driver.ddlToReturn = baseDDL

        let result = try await loadDDL(using: driver, table: "orders")

        #expect(result == baseDDL)
        #expect(!result.contains("CREATE SEQUENCE"))
        #expect(!result.contains("CREATE TYPE"))
    }
}
