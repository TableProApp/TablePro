//
//  SQLStatementGeneratorCompositePKTests.swift
//  TableProTests
//
//  Tests for composite primary key support in UPDATE and DELETE generation.
//

@testable import TablePro
import Testing

@Suite("SQL Statement Generator — Composite Primary Key")
struct SQLStatementGeneratorCompositePKTests {
    // MARK: - Helpers

    private func makeGenerator(
        tableName: String = "order_items",
        columns: [String] = ["order_id", "product_id", "quantity", "price"],
        primaryKeyColumns: [String] = ["order_id", "product_id"],
        databaseType: DatabaseType = .mysql
    ) -> SQLStatementGenerator {
        SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            dialect: nil
        )
    }

    private func makeUpdateChange(
        rowIndex: Int = 0,
        columnIndex: Int,
        columnName: String,
        oldValue: String?,
        newValue: String?,
        originalRow: [String?]
    ) -> RowChange {
        RowChange(
            rowIndex: rowIndex,
            type: .update,
            cellChanges: [CellChange(
                rowIndex: rowIndex, columnIndex: columnIndex,
                columnName: columnName, oldValue: oldValue, newValue: newValue
            )],
            originalRow: originalRow
        )
    }

    private func makeMultiCellUpdateChange(
        rowIndex: Int = 0,
        cellChanges: [CellChange],
        originalRow: [String?]
    ) -> RowChange {
        RowChange(
            rowIndex: rowIndex,
            type: .update,
            cellChanges: cellChanges,
            originalRow: originalRow
        )
    }

    private func makeDeleteChange(rowIndex: Int = 0, originalRow: [String?]) -> RowChange {
        RowChange(rowIndex: rowIndex, type: .delete, cellChanges: [], originalRow: originalRow)
    }

    private func generate(
        _ changes: [RowChange],
        generator: SQLStatementGenerator,
        deletedRowIndices: Set<Int> = [],
        insertedRowIndices: Set<Int> = []
    ) -> [ParameterizedStatement] {
        generator.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    // MARK: - UPDATE: Composite PK WHERE Clause

    @Test("UPDATE with 2-column composite PK produces AND in WHERE")
    func updateCompositePKBasic() {
        let gen = makeGenerator()
        let stmts = generate([
            makeUpdateChange(
                columnIndex: 2, columnName: "quantity",
                oldValue: "5", newValue: "10",
                originalRow: ["1", "42", "5", "9.99"]
            ),
        ], generator: gen)

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("`order_id` = ?"))
        #expect(stmts[0].sql.contains("`product_id` = ?"))
        #expect(stmts[0].sql.contains(" AND "))
        #expect(stmts[0].parameters.count == 3) // SET quantity + WHERE order_id, product_id
    }

    @Test("UPDATE with 3-column composite PK produces multiple ANDs")
    func updateThreeColumnCompositePK() {
        let gen = makeGenerator(
            columns: ["tenant_id", "user_id", "role_id", "active"],
            primaryKeyColumns: ["tenant_id", "user_id", "role_id"]
        )
        let stmts = generate([
            makeUpdateChange(
                columnIndex: 3, columnName: "active",
                oldValue: "1", newValue: "0",
                originalRow: ["t1", "u1", "r1", "1"]
            ),
        ], generator: gen)

        #expect(stmts.count == 1)
        let sql = stmts[0].sql
        #expect(sql.contains("`tenant_id` = ?"))
        #expect(sql.contains("`user_id` = ?"))
        #expect(sql.contains("`role_id` = ?"))
        #expect(stmts[0].parameters.count == 4) // SET active + 3 PK values
    }

    @Test("UPDATE preserves correct parameter order: SET values before WHERE values")
    func updateParameterOrder() {
        let gen = makeGenerator()
        let stmts = generate([
            makeUpdateChange(
                columnIndex: 2, columnName: "quantity",
                oldValue: "5", newValue: "10",
                originalRow: ["1", "42", "5", "9.99"]
            ),
        ], generator: gen)

        #expect(stmts.count == 1)
        let params = stmts[0].parameters
        #expect(params[0] as? String == "10")  // SET quantity = ?
        #expect(params[1] as? String == "1")   // WHERE order_id = ?
        #expect(params[2] as? String == "42")  // AND product_id = ?
    }

    @Test("UPDATE multiple columns on same row with composite PK")
    func updateMultipleColumnsCompositePK() {
        let gen = makeGenerator()
        let stmts = generate([
            makeMultiCellUpdateChange(
                cellChanges: [
                    CellChange(rowIndex: 0, columnIndex: 2, columnName: "quantity", oldValue: "5", newValue: "10"),
                    CellChange(rowIndex: 0, columnIndex: 3, columnName: "price", oldValue: "9.99", newValue: "12.99"),
                ],
                originalRow: ["1", "42", "5", "9.99"]
            ),
        ], generator: gen)

        #expect(stmts.count == 1)
        let sql = stmts[0].sql
        #expect(sql.contains("`quantity` = ?"))
        #expect(sql.contains("`price` = ?"))
        #expect(sql.contains("`order_id` = ?"))
        #expect(sql.contains("`product_id` = ?"))
        #expect(stmts[0].parameters.count == 4) // 2 SET + 2 WHERE
    }

    @Test("UPDATE where user edits a PK column uses original value in WHERE")
    func updateEditsPKColumn() {
        let gen = makeGenerator()
        let stmts = generate([
            makeUpdateChange(
                columnIndex: 1, columnName: "product_id",
                oldValue: "42", newValue: "99",
                originalRow: ["1", "42", "5", "9.99"]
            ),
        ], generator: gen)

        #expect(stmts.count == 1)
        let params = stmts[0].parameters
        // SET product_id = 99 (new), WHERE order_id = 1, product_id = 42 (original)
        #expect(params[0] as? String == "99")  // SET
        #expect(params[1] as? String == "1")   // WHERE order_id (from originalRow)
        #expect(params[2] as? String == "42")  // WHERE product_id (from originalRow)
    }

    @Test("Multiple UPDATE changes generate separate statements")
    func multipleUpdatesCompositePK() {
        let gen = makeGenerator()
        let stmts = generate([
            makeUpdateChange(
                rowIndex: 0, columnIndex: 2, columnName: "quantity",
                oldValue: "5", newValue: "10",
                originalRow: ["1", "42", "5", "9.99"]
            ),
            makeUpdateChange(
                rowIndex: 1, columnIndex: 2, columnName: "quantity",
                oldValue: "3", newValue: "7",
                originalRow: ["1", "43", "3", "4.99"]
            ),
        ], generator: gen)

        #expect(stmts.count == 2)
        // First UPDATE: WHERE order_id=1 AND product_id=42
        #expect(stmts[0].parameters[1] as? String == "1")
        #expect(stmts[0].parameters[2] as? String == "42")
        // Second UPDATE: WHERE order_id=1 AND product_id=43
        #expect(stmts[1].parameters[1] as? String == "1")
        #expect(stmts[1].parameters[2] as? String == "43")
    }

    // MARK: - UPDATE: Database Dialects

    @Test("PostgreSQL UPDATE with composite PK uses $N placeholders")
    func updateCompositePKPostgreSQL() {
        let gen = makeGenerator(databaseType: .postgresql)
        let stmts = generate([
            makeUpdateChange(
                columnIndex: 2, columnName: "quantity",
                oldValue: "5", newValue: "10",
                originalRow: ["1", "42", "5", "9.99"]
            ),
        ], generator: gen)

        #expect(stmts.count == 1)
        let sql = stmts[0].sql
        #expect(sql.contains("$1")) // SET quantity
        #expect(sql.contains("$2")) // WHERE order_id
        #expect(sql.contains("$3")) // AND product_id
    }

    @Test("MSSQL UPDATE with composite PK uses bracket quoting")
    func updateCompositePKMSSQL() {
        let gen = makeGenerator(databaseType: .mssql)
        let stmts = generate([
            makeUpdateChange(
                columnIndex: 2, columnName: "quantity",
                oldValue: "5", newValue: "10",
                originalRow: ["1", "42", "5", "9.99"]
            ),
        ], generator: gen)

        #expect(stmts.count == 1)
        let sql = stmts[0].sql
        #expect(sql.contains("[order_id] = ?"))
        #expect(sql.contains("[product_id] = ?"))
    }

    // MARK: - DELETE: Composite PK

    @Test("Single row DELETE with composite PK uses AND")
    func deleteSingleRowCompositePK() {
        let gen = makeGenerator()
        let stmts = generate(
            [makeDeleteChange(rowIndex: 0, originalRow: ["1", "42", "5", "9.99"])],
            generator: gen,
            deletedRowIndices: [0]
        )

        #expect(stmts.count == 1)
        let sql = stmts[0].sql
        #expect(sql.hasPrefix("DELETE FROM"))
        #expect(sql.contains("`order_id` = ?"))
        #expect(sql.contains("`product_id` = ?"))
        #expect(sql.contains(" AND "))
        #expect(!sql.contains("`quantity`"))
        #expect(!sql.contains("`price`"))
        #expect(stmts[0].parameters.count == 2)
    }

    @Test("Batch DELETE with composite PK: (AND) per row, OR between rows")
    func batchDeleteCompositePK() {
        let gen = makeGenerator()
        let stmts = generate(
            [
                makeDeleteChange(rowIndex: 0, originalRow: ["1", "42", "5", "9.99"]),
                makeDeleteChange(rowIndex: 1, originalRow: ["1", "43", "3", "4.99"]),
                makeDeleteChange(rowIndex: 2, originalRow: ["2", "42", "1", "7.50"]),
            ],
            generator: gen,
            deletedRowIndices: [0, 1, 2]
        )

        #expect(stmts.count == 1)
        let sql = stmts[0].sql
        #expect(sql.contains("("))
        #expect(sql.contains(")"))
        #expect(sql.contains(" OR "))
        #expect(stmts[0].parameters.count == 6) // 3 rows × 2 PK columns
    }

    @Test("Batch DELETE with composite PK on PostgreSQL uses $N")
    func batchDeleteCompositePKPostgreSQL() {
        let gen = makeGenerator(databaseType: .postgresql)
        let stmts = generate(
            [
                makeDeleteChange(rowIndex: 0, originalRow: ["1", "42", "5", "9.99"]),
                makeDeleteChange(rowIndex: 1, originalRow: ["1", "43", "3", "4.99"]),
            ],
            generator: gen,
            deletedRowIndices: [0, 1]
        )

        #expect(stmts.count == 1)
        let sql = stmts[0].sql
        #expect(sql.contains("$1")) // row 1 order_id
        #expect(sql.contains("$2")) // row 1 product_id
        #expect(sql.contains("$3")) // row 2 order_id
        #expect(sql.contains("$4")) // row 2 product_id
    }

    // MARK: - Single PK Regression

    @Test("Single PK UPDATE still works (regression)")
    func singlePKUpdateRegression() {
        let gen = makeGenerator(
            tableName: "users",
            columns: ["id", "name", "email"],
            primaryKeyColumns: ["id"]
        )
        let stmts = generate([
            makeUpdateChange(
                columnIndex: 1, columnName: "name",
                oldValue: "John", newValue: "Jane",
                originalRow: ["1", "John", "john@test.com"]
            ),
        ], generator: gen)

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("WHERE `id` = ?"))
        #expect(!stmts[0].sql.contains(" AND "))
        #expect(stmts[0].parameters.count == 2)
    }

    @Test("Single PK batch DELETE no parentheses (regression)")
    func singlePKBatchDeleteRegression() {
        let gen = makeGenerator(
            tableName: "users",
            columns: ["id", "name", "email"],
            primaryKeyColumns: ["id"]
        )
        let stmts = generate(
            [
                makeDeleteChange(rowIndex: 0, originalRow: ["1", "John", "john@test.com"]),
                makeDeleteChange(rowIndex: 1, originalRow: ["2", "Jane", "jane@test.com"]),
            ],
            generator: gen,
            deletedRowIndices: [0, 1]
        )

        #expect(stmts.count == 1)
        let sql = stmts[0].sql
        // Single PK: no parentheses around conditions
        #expect(!sql.contains("("))
        #expect(sql.contains("`id` = ?"))
        #expect(sql.contains(" OR "))
    }

    // MARK: - No PK Fallback

    @Test("No PK UPDATE falls back to all-column WHERE")
    func noPKUpdateFallback() {
        let gen = makeGenerator(
            tableName: "logs",
            columns: ["ts", "message", "level"],
            primaryKeyColumns: []
        )
        let stmts = generate([
            makeUpdateChange(
                columnIndex: 2, columnName: "level",
                oldValue: "info", newValue: "warn",
                originalRow: ["2024-01-01", "hello", "info"]
            ),
        ], generator: gen)

        #expect(stmts.count == 1)
        let sql = stmts[0].sql
        #expect(sql.contains("`ts` = ?"))
        #expect(sql.contains("`message` = ?"))
        #expect(sql.contains("`level` = ?"))
    }

    @Test("No PK DELETE uses individual per-row statements with all columns")
    func noPKDeleteFallback() {
        let gen = makeGenerator(
            tableName: "logs",
            columns: ["ts", "message", "level"],
            primaryKeyColumns: []
        )
        let stmts = generate(
            [
                makeDeleteChange(rowIndex: 0, originalRow: ["2024-01-01", "hello", "info"]),
                makeDeleteChange(rowIndex: 1, originalRow: ["2024-01-02", "world", "warn"]),
            ],
            generator: gen,
            deletedRowIndices: [0, 1]
        )

        // No PK batch delete returns nil → individual deletes
        #expect(stmts.count == 2)
        #expect(stmts[0].sql.contains("`ts` = ?"))
        #expect(stmts[0].sql.contains("`message` = ?"))
        #expect(stmts[0].sql.contains("`level` = ?"))
    }

    @Test("No PK fallback handles NULL values with IS NULL")
    func noPKFallbackNullHandling() {
        let gen = makeGenerator(
            tableName: "logs",
            columns: ["ts", "message", "level"],
            primaryKeyColumns: []
        )
        let stmts = generate([
            makeUpdateChange(
                columnIndex: 2, columnName: "level",
                oldValue: nil, newValue: "warn",
                originalRow: ["2024-01-01", nil, nil]
            ),
        ], generator: gen)

        #expect(stmts.count == 1)
        let sql = stmts[0].sql
        #expect(sql.contains("`message` IS NULL"))
        #expect(sql.contains("`level` IS NULL"))
        #expect(sql.contains("`ts` = ?"))
    }

    // MARK: - Edge Cases

    @Test("Composite PK with NULL value in one PK column skips UPDATE")
    func compositePKNullValueSkipsUpdate() {
        let gen = makeGenerator()
        let stmts = generate([
            makeUpdateChange(
                columnIndex: 2, columnName: "quantity",
                oldValue: "5", newValue: "10",
                originalRow: ["1", nil, "5", "9.99"]
            ),
        ], generator: gen)

        #expect(stmts.isEmpty)
    }

    @Test("Composite PK with NULL in one PK column skips batch DELETE for that row")
    func compositePKNullValueInBatchDelete() {
        let gen = makeGenerator()
        let stmts = generate(
            [
                makeDeleteChange(rowIndex: 0, originalRow: ["1", nil, "5", "9.99"]),
                makeDeleteChange(rowIndex: 1, originalRow: ["1", "43", "3", "4.99"]),
            ],
            generator: gen,
            deletedRowIndices: [0, 1]
        )

        // Row 0 has NULL PK → skipped in batch, only row 1 survives
        #expect(stmts.count == 1)
        #expect(stmts[0].parameters.count == 2) // Only row 1's 2 PK values
    }

    @Test("UPDATE without originalRow falls back to cellChanges for PK value")
    func updateWithoutOriginalRowUsesCellChanges() {
        let gen = makeGenerator()
        let change = RowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                CellChange(rowIndex: 0, columnIndex: 0, columnName: "order_id", oldValue: "1", newValue: "1"),
                CellChange(rowIndex: 0, columnIndex: 1, columnName: "product_id", oldValue: "42", newValue: "42"),
                CellChange(rowIndex: 0, columnIndex: 2, columnName: "quantity", oldValue: "5", newValue: "10"),
            ],
            originalRow: nil
        )

        let stmts = generate([change], generator: gen)

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("`order_id` = ?"))
        #expect(stmts[0].sql.contains("`product_id` = ?"))
    }

    @Test("UPDATE without originalRow and missing PK in cellChanges is skipped")
    func updateWithoutOriginalRowMissingPKSkipped() {
        let gen = makeGenerator()
        let change = RowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                CellChange(rowIndex: 0, columnIndex: 2, columnName: "quantity", oldValue: "5", newValue: "10"),
            ],
            originalRow: nil // No originalRow, and only quantity in cellChanges — missing PK columns
        )

        let stmts = generate([change], generator: gen)

        #expect(stmts.isEmpty)
    }

    @Test("Mixed INSERT + UPDATE + DELETE with composite PK generates correct statements")
    func mixedOperationsCompositePK() {
        let gen = makeGenerator()

        let insertChange = RowChange(rowIndex: 3, type: .insert, cellChanges: [])
        let updateChange = makeUpdateChange(
            rowIndex: 0, columnIndex: 2, columnName: "quantity",
            oldValue: "5", newValue: "10",
            originalRow: ["1", "42", "5", "9.99"]
        )
        let deleteChange = makeDeleteChange(rowIndex: 1, originalRow: ["1", "43", "3", "4.99"])

        let stmts = gen.generateStatements(
            from: [insertChange, updateChange, deleteChange],
            insertedRowData: [3: ["2", "99", "1", "5.00"]],
            deletedRowIndices: [1],
            insertedRowIndices: [3]
        )

        // INSERT + UPDATE + DELETE = 3 statements
        #expect(stmts.count == 3)

        let insertSQL = stmts.first { $0.sql.hasPrefix("INSERT") }
        let updateSQL = stmts.first { $0.sql.hasPrefix("UPDATE") }
        let deleteSQL = stmts.first { $0.sql.hasPrefix("DELETE") }

        #expect(insertSQL != nil)
        #expect(updateSQL != nil)
        #expect(deleteSQL != nil)
        #expect(updateSQL!.sql.contains("`order_id` = ?"))
        #expect(updateSQL!.sql.contains("`product_id` = ?"))
        #expect(deleteSQL!.sql.contains("`order_id` = ?"))
        #expect(deleteSQL!.sql.contains("`product_id` = ?"))
    }
}
