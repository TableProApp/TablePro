import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// The shared write path is keyed by the type id exactly as both apps spell it; a lower-cased or respelled id falls to
// the generic answers without a word.
struct TransferEngineIdTests {
    struct Engine: Sendable, CustomTestStringConvertible {
        let databaseType: DatabaseType
        let id: String
        let maxBindParameters: Int
        let maxRowsPerInsert: Int
        let allDefaults: String?
        let integerType: String
        let booleanType: String
        let rendersValuesAsLiterals: Bool

        var testDescription: String { id }
    }

    static let iosEngines: [Engine] = [
        Engine(
            databaseType: .mysql, id: "MySQL", maxBindParameters: 65_535, maxRowsPerInsert: .max,
            allDefaults: "INSERT INTO t () VALUES ()", integerType: "BIGINT", booleanType: "TINYINT(1)",
            rendersValuesAsLiterals: false
        ),
        Engine(
            databaseType: .mariadb, id: "MariaDB", maxBindParameters: 65_535, maxRowsPerInsert: .max,
            allDefaults: "INSERT INTO t () VALUES ()", integerType: "BIGINT", booleanType: "TINYINT(1)",
            rendersValuesAsLiterals: false
        ),
        Engine(
            databaseType: .tidb, id: "TiDB", maxBindParameters: 65_535, maxRowsPerInsert: .max,
            allDefaults: "INSERT INTO t () VALUES ()", integerType: "BIGINT", booleanType: "TINYINT(1)",
            rendersValuesAsLiterals: false
        ),
        Engine(
            databaseType: .oceanbase, id: "OceanBase", maxBindParameters: 65_535, maxRowsPerInsert: .max,
            allDefaults: "INSERT INTO t () VALUES ()", integerType: "BIGINT", booleanType: "TINYINT(1)",
            rendersValuesAsLiterals: false
        ),
        Engine(
            databaseType: .postgresql, id: "PostgreSQL", maxBindParameters: 65_535, maxRowsPerInsert: .max,
            allDefaults: "INSERT INTO t DEFAULT VALUES", integerType: "BIGINT", booleanType: "BOOLEAN",
            rendersValuesAsLiterals: false
        ),
        Engine(
            databaseType: .redshift, id: "Redshift", maxBindParameters: 65_535, maxRowsPerInsert: .max,
            allDefaults: "INSERT INTO t DEFAULT VALUES", integerType: "BIGINT", booleanType: "BOOLEAN",
            rendersValuesAsLiterals: false
        ),
        Engine(
            databaseType: .sqlite, id: "SQLite", maxBindParameters: 32_766, maxRowsPerInsert: .max,
            allDefaults: "INSERT INTO t DEFAULT VALUES", integerType: "INTEGER", booleanType: "BOOLEAN",
            rendersValuesAsLiterals: false
        ),
        Engine(
            databaseType: .duckdb, id: "DuckDB", maxBindParameters: 65_535, maxRowsPerInsert: .max,
            allDefaults: "INSERT INTO t DEFAULT VALUES", integerType: "INTEGER", booleanType: "BOOLEAN",
            rendersValuesAsLiterals: false
        ),
        Engine(
            databaseType: .mssql, id: "SQL Server", maxBindParameters: 2_100, maxRowsPerInsert: 1_000,
            allDefaults: "INSERT INTO t DEFAULT VALUES", integerType: "BIGINT", booleanType: "BIT",
            rendersValuesAsLiterals: false
        ),
        Engine(
            databaseType: .oracle, id: "Oracle", maxBindParameters: 65_535, maxRowsPerInsert: 1,
            allDefaults: "INSERT INTO t (c) VALUES (DEFAULT)", integerType: "NUMBER(19)",
            booleanType: "VARCHAR2(5 CHAR)", rendersValuesAsLiterals: false
        ),
        Engine(
            databaseType: .clickhouse, id: "ClickHouse", maxBindParameters: 65_535, maxRowsPerInsert: .max,
            allDefaults: nil, integerType: "INTEGER", booleanType: "BOOLEAN", rendersValuesAsLiterals: true
        ),
        Engine(
            databaseType: .cloudflareD1, id: "Cloudflare D1", maxBindParameters: 100, maxRowsPerInsert: .max,
            allDefaults: "INSERT INTO t DEFAULT VALUES", integerType: "INTEGER", booleanType: "BOOLEAN",
            rendersValuesAsLiterals: false
        ),
    ]

    @Test(
        "Each engine the iOS app imports into gets its own answers from its type id",
        arguments: TransferEngineIdTests.iosEngines
    )
    func engineAnswers(engine: Engine) {
        #expect(engine.databaseType.rawValue == engine.id)

        let statements = SQLImportStatements(
            databaseTypeId: engine.id, qualifiedTableName: "t", parameterStyle: .questionMark, quoteIdentifier: { $0 }
        )
        #expect(statements.maxBindParameters == engine.maxBindParameters)
        #expect(statements.maxRowsPerInsert == engine.maxRowsPerInsert)
        #expect(statements.rendersValuesAsLiterals == engine.rendersValuesAsLiterals)
        #expect(statements.allDefaultsInsertStatement(firstColumn: "c")?.sql == engine.allDefaults)
        #expect(ImportTypeMapper.sqlType(for: .integer, databaseTypeId: engine.id) == engine.integerType)
        #expect(ImportTypeMapper.sqlType(for: .boolean, databaseTypeId: engine.id) == engine.booleanType)
    }

    @Test("A lower-cased type id gets the generic answers")
    func lowerCasedIdIsGeneric() {
        let statements = SQLImportStatements(
            databaseTypeId: "sql server", qualifiedTableName: "t", parameterStyle: .questionMark, quoteIdentifier: { $0 }
        )
        #expect(statements.maxBindParameters == 65_535)
        #expect(ImportTypeMapper.sqlType(for: .boolean, databaseTypeId: "sql server") == "BOOLEAN")
    }

    @Test("Only PostgreSQL itself reads its JSON column type from the server version")
    func postgresJSONColumnTypeById() {
        #expect(ImportTypeMapper.postgresJSONColumnType(databaseTypeId: "PostgreSQL", serverVersion: "9.3.25") == .json)
        #expect(ImportTypeMapper.postgresJSONColumnType(databaseTypeId: "Redshift", serverVersion: "8.0.2") == .jsonb)
    }
}
