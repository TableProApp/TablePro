import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct SQLImportStatementsTests {
    private func statements(
        _ databaseTypeId: String = "MySQL",
        style: ParameterStyle = .questionMark,
        typeNames: [String: String] = [:],
        bitColumns: Set<String> = [],
        rowDelete: ((_ table: String, _ predicate: String?) -> String?)? = nil
    ) -> SQLImportStatements {
        SQLImportStatements(
            databaseTypeId: databaseTypeId,
            qualifiedTableName: "\"t\"",
            parameterStyle: style,
            quoteIdentifier: { "\"\($0)\"" },
            columnTypeNames: typeNames,
            numberBitColumns: bitColumns,
            rowDeleteStatement: rowDelete
        )
    }

    @Test("Question-mark placeholders repeat, dollar placeholders count across every row")
    func placeholderStyles() throws {
        let rows: [[PluginCellValue]] = [["1", "a"], ["2", "b"]]
        let question = try #require(statements().insertStatement(columns: ["id", "name"], rows: rows))
        #expect(question.sql == "INSERT INTO \"t\" (\"id\", \"name\") VALUES (?, ?), (?, ?)")
        let dollar = try #require(
            statements("PostgreSQL", style: .dollar).insertStatement(columns: ["id", "name"], rows: rows)
        )
        #expect(dollar.sql == "INSERT INTO \"t\" (\"id\", \"name\") VALUES ($1, $2), ($3, $4)")
        #expect(dollar.parameters == ["1", "a", "2", "b"])
        #expect(dollar.parameterTypeNames == nil)
    }

    @Test("A keyed update numbers its SET and WHERE placeholders as one list")
    func keyedUpdateNumbersAcrossClauses() throws {
        let update = try #require(statements("PostgreSQL", style: .dollar).keyedUpdateStatement(
            columns: ["name"], values: ["Ada"], keyColumns: ["tenant", "id"], keyValues: ["t1", "7"]
        ))
        #expect(update.sql == "UPDATE \"t\" SET \"name\" = $1 WHERE \"tenant\" = $2 AND \"id\" = $3")
        #expect(update.parameters == ["Ada", "t1", "7"])
    }

    @Test("The match probe tags each key with its position and binds a NULL key part as NULL")
    func matchProbe() throws {
        let probe = try #require(statements().keyMatchCountStatement(keyColumns: ["id"], keys: [["1"], [.null]]))
        #expect(probe.sql == """
            SELECT 0, COUNT(*) FROM "t" WHERE "id" = ? UNION ALL SELECT 1, COUNT(*) FROM "t" WHERE "id" = ?
            """)
        #expect(probe.parameters == ["1", .null])
    }

    @Test("A MySQL BIT column takes decimal text through CAST(? AS UNSIGNED), with no column type on the operand")
    func mysqlBitColumn() throws {
        let insert = try #require(
            statements(typeNames: ["flags": "bit(8)", "name": "varchar(10)"], bitColumns: ["flags"])
                .insertStatement(columns: ["flags", "name"], values: ["b'101'", "x"])
        )
        #expect(insert.sql == "INSERT INTO \"t\" (\"flags\", \"name\") VALUES (CAST(? AS UNSIGNED), ?)")
        #expect(insert.parameters == ["5", "x"])
        #expect(insert.parameterTypeNames == [nil, "varchar(10)"])
    }

    @Test("Blank text for a BIT column goes as empty text bound to the column")
    func mysqlBitBlank() throws {
        let insert = try #require(
            statements(typeNames: ["flags": "bit(8)"], bitColumns: ["flags"])
                .insertStatement(columns: ["flags"], values: ["  "])
        )
        #expect(insert.sql == "INSERT INTO \"t\" (\"flags\") VALUES (?)")
        #expect(insert.parameters == [""])
        #expect(insert.parameterTypeNames == ["bit(8)"])
    }

    @Test("Bit literals and boolean words read as decimal text")
    func decimalBitText() {
        #expect(SQLImportStatements.decimalBitText("0b11") == "3")
        #expect(SQLImportStatements.decimalBitText("TRUE") == "1")
        #expect(SQLImportStatements.decimalBitText("f") == "0")
        #expect(SQLImportStatements.decimalBitText("12") == "12")
    }

    @Test("Oracle writes one row per INSERT, so its batches hold one row")
    func oracleOneRowCeiling() {
        let oracle = statements("Oracle")
        #expect(oracle.maxRowsPerInsert == 1)
        #expect(SQLWriteBatchBudget(columnCount: 2, statements: oracle).maxRows == 1)
    }

    @Test("Cloudflare D1 binds 100 parameters, so a batch holds 100 over the row width")
    func cloudflareD1BindCeiling() {
        let d1 = statements("Cloudflare D1")
        #expect(d1.maxBindParameters == 100)
        #expect(SQLWriteBatchBudget(columnCount: 3, statements: d1).maxRows == 33)
    }

    @Test("A host's own ceilings and literal rendering replace the type id's")
    func hostOverrides() {
        let inlined = SQLImportStatements(
            databaseTypeId: "MySQL",
            qualifiedTableName: "`t`",
            parameterStyle: .questionMark,
            quoteIdentifier: { "`\($0)`" },
            maxBindParameters: 10,
            maxRowsPerInsert: 4,
            rendersValuesAsLiterals: true
        )
        let budget = SQLWriteBatchBudget(columnCount: 2, statements: inlined)
        #expect(budget.maxRows == 4)
        #expect(budget.rendersValuesAsLiterals)
    }

    @Test("Clearing the table uses the host's row-delete form when it has one")
    func deleteAllRows() {
        #expect(statements().deleteAllRowsStatement() == "DELETE FROM \"t\"")
        let truncating = statements(rowDelete: { table, _ in "TRUNCATE TABLE \(table)" })
        #expect(truncating.deleteAllRowsStatement() == "TRUNCATE TABLE \"t\"")
    }
}
