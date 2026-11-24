import Foundation
import Testing

@testable import TableProMySQLCore

struct MySQLExportQueryTests {
    @Test("A function drop names the function kind, qualified by its database")
    func functionDrop() {
        let sql = MySQLObjectQueries.dropRoutine(
            isFunction: true, schema: "app", name: "total", quote: MySQLObjectQueries.quoteIdentifier
        )
        #expect(sql == "DROP FUNCTION IF EXISTS `app`.`total`")
    }

    @Test("A procedure drop says PROCEDURE, never ROUTINE")
    func procedureDrop() {
        let sql = MySQLObjectQueries.dropRoutine(
            isFunction: false, schema: "app", name: "cleanup", quote: MySQLObjectQueries.quoteIdentifier
        )
        #expect(sql == "DROP PROCEDURE IF EXISTS `app`.`cleanup`")
        #expect(!sql.contains("ROUTINE"))
    }

    @Test("A routine drop with no database is unqualified")
    func unqualifiedRoutineDrop() {
        let sql = MySQLObjectQueries.dropRoutine(
            isFunction: false, schema: nil, name: "p", quote: MySQLObjectQueries.quoteIdentifier
        )
        #expect(sql == "DROP PROCEDURE IF EXISTS `p`")
    }

    @Test("A drop quotes with the caller's quoter")
    func dropUsesCallerQuote() {
        let sql = MySQLObjectQueries.dropRoutine(isFunction: true, schema: "d", name: "f", quote: { "\"\($0)\"" })
        #expect(sql == "DROP FUNCTION IF EXISTS \"d\".\"f\"")
    }

    @Test("A trigger drop is qualified and doubles a backtick in the name")
    func triggerDrop() {
        let sql = MySQLObjectQueries.dropTrigger(schema: "app", name: "a`b", quote: MySQLObjectQueries.quoteIdentifier)
        #expect(sql == "DROP TRIGGER `app`.`a``b`")
    }

    @Test("The bulk column read covers the database, ordered for the per-table grouping")
    func columnCatalogForDatabase() {
        let sql = MySQLObjectQueries.columnCatalog(schema: "app", table: nil, projectsGenerationExpression: true)
        #expect(sql == """
            SELECT
                TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, COLLATION_NAME,
                IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT,
                GENERATION_EXPRESSION
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = 'app'
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """)
    }

    @Test("The column read narrows to one table and projects NULL where the catalog has no expression column")
    func columnCatalogForTable() {
        let sql = MySQLObjectQueries.columnCatalog(schema: "a'b", table: "t'1", projectsGenerationExpression: false)
        #expect(sql.contains("WHERE TABLE_SCHEMA = 'a''b' AND TABLE_NAME = 't''1'\n"))
        #expect(sql.contains("COLUMN_COMMENT,\n    NULL\n"))
        #expect(!sql.contains("GENERATION_EXPRESSION"))
    }

    @Test("The row count read escapes both names")
    func approximateRowCount() {
        let sql = MySQLObjectQueries.approximateRowCount(schema: "app", table: "o'rders")
        #expect(sql == """
            SELECT TABLE_ROWS
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = 'app'
              AND TABLE_NAME = 'o''rders'
            """)
    }
}
