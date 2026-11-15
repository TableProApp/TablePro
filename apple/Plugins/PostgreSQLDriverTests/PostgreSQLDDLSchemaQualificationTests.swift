import TableProPluginKit
import Testing

struct PostgreSQLDDLSchemaQualificationTests {
    private let driver = PostgreSQLPluginDriver(config: DriverConnectionConfig(
        host: "", port: 0, username: "", password: "", database: ""
    ))
    private let column = PluginColumnDefinition(name: "note", dataType: "text")

    @Test("Every table statement names the schema it is given, not the session's")
    func alterStatementsNameTheGivenSchema() throws {
        let statements: [String?] = [
            driver.generateAddColumnSQL(table: "orders", schema: "sales", column: column),
            driver.generateModifyColumnSQL(
                table: "orders", schema: "sales",
                oldColumn: column, newColumn: PluginColumnDefinition(name: "memo", dataType: "text")
            ),
            driver.generateDropColumnSQL(table: "orders", schema: "sales", columnName: "note"),
            driver.generateAddIndexSQL(
                table: "orders", schema: "sales", index: PluginIndexDefinition(name: "orders_note", columns: ["note"])
            ),
            driver.generateDropIndexSQL(table: "orders", schema: "sales", indexName: "orders_note"),
            driver.generateAddForeignKeySQL(
                table: "orders", schema: "sales",
                fk: PluginForeignKeyDefinition(
                    name: "orders_customer", columns: ["customer_id"], referencedTable: "customers", referencedColumns: ["id"]
                )
            ),
            driver.generateDropForeignKeySQL(table: "orders", schema: "sales", constraintName: "orders_customer"),
            driver.generateAddCheckConstraintSQL(
                table: "orders", schema: "sales",
                constraint: PluginCheckConstraintDefinition(name: "positive", expression: "total > 0")
            ),
            driver.generateDropCheckConstraintSQL(table: "orders", schema: "sales", constraintName: "positive")
        ]
        let primaryKey = try #require(driver.generateModifyPrimaryKeySQL(
            table: "orders", schema: "sales", oldColumns: ["id"], newColumns: ["id", "line"], constraintName: "orders_pkey"
        ))
        let created = try #require(driver.generateCreateTableStatements(
            definition: PluginCreateTableDefinition(tableName: "orders", columns: [column]), schema: "sales"
        ))

        for sql in statements.map({ $0 ?? "" }) + primaryKey + created {
            #expect(sql.contains("\"sales\"."), "\(sql)")
            #expect(!sql.contains("\"public\""), "\(sql)")
        }
    }

    @Test("No schema falls back to the session's")
    func nilSchemaUsesTheSessionSchema() {
        #expect(
            driver.generateDropColumnSQL(table: "orders", schema: nil, columnName: "note")
                == "ALTER TABLE \"public\".\"orders\" DROP COLUMN \"note\""
        )
    }
}
