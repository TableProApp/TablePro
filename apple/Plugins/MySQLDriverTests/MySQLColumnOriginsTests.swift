import CMariaDB
import Foundation
import TableProPluginKit
import Testing

struct MySQLColumnOriginsTests {
    @Test("A plain projection keeps the origins the server reports, an alias included")
    func plainProjectionIsTrusted() {
        #expect(MySQLColumnOrigins.readsTableColumnsDirectly("SELECT email AS e FROM users"))
        #expect(MySQLColumnOrigins.readsTableColumnsDirectly("select u.email id, lower(name) from shop.users u where id = 1"))
        #expect(MySQLColumnOrigins.readsTableColumnsDirectly("SELECT table_name FROM information_schema.tables"))
        #expect(MySQLColumnOrigins.readsTableColumnsDirectly("DELETE FROM users RETURNING email AS e"))
    }

    // Measured: the server reports `s.e`, `c.e` or `users.e` for these, the alias the statement chose.
    @Test("A derived table, a CTE, JSON_TABLE or a procedure drops every origin")
    func renamingShapesAreNotTrusted() {
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT e FROM (SELECT email AS e FROM users) s"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT e FROM(SELECT email AS e FROM users)s"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("WITH c AS (SELECT email AS e FROM users) SELECT e FROM c"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT * FROM (TABLE users) x"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT e FROM (VALUES ROW('a')) x(e)"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly(
            "SELECT j.id FROM users, json_table(users.doc, '$' COLUMNS (id VARCHAR(50) PATH '$.email')) j"
        ))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("CALL leak()"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("EXECUTE prepared"))
    }

    @Test("A set operation drops every origin, even with its keyword glued to a number")
    func setOperationsAreNotTrusted() {
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT id FROM t UNION SELECT email FROM users"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT id FROM t WHERE id = 1.0union SELECT email FROM users"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT id FROM t WHERE id = 1e0union TABLE users"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT id FROM t /*!UNION*/ SELECT 1"))
    }

    // Measured on MariaDB 13.0.2: the server ran the inner SELECT and reported `p.s.e` for the e-mail column.
    @Test("An executable comment drops every origin, even with its version glued to a keyword")
    func executableCommentsAreNotTrusted() {
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT e FROM (/*!100000SELECT*/ email AS e FROM users) s"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT e FROM (/*!50000SELECT*/ email AS e FROM users) s"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT e FROM (/*M!100000SELECT*/ email AS e FROM users) s"))
        #expect(!MySQLColumnOrigins.readsTableColumnsDirectly("SELECT email /*!AS e*/ FROM users"))
        #expect(MySQLColumnOrigins.readsTableColumnsDirectly("SELECT email /* AS e */ FROM users"))
    }

    @Test("An identifier that only contains a keyword keeps the origins")
    func identifiersAreNotKeywords() {
        #expect(MySQLColumnOrigins.readsTableColumnsDirectly("SELECT withdrawn, table_name, selected FROM tables_with_values"))
    }

    @Test("A field names its schema, table and column only when the server gave all three")
    func fieldOrigin() {
        let traced = Self.field(db: "shop", table: "users", column: "email")
        defer { Self.release(traced) }
        #expect(
            MySQLColumnOrigins.origin(of: traced, encoding: .utf8)
                == PluginColumnOrigin(schema: "shop", table: "users", column: "email")
        )

        let expression = Self.field(db: "", table: "", column: "")
        defer { Self.release(expression) }
        #expect(MySQLColumnOrigins.origin(of: expression, encoding: .utf8) == nil)

        let jsonTable = Self.field(db: "*any*", table: "json_table", column: "x")
        defer { Self.release(jsonTable) }
        #expect(MySQLColumnOrigins.origin(of: jsonTable, encoding: .utf8) == nil)

        let recursive = Self.field(db: "", table: "", column: "e")
        defer { Self.release(recursive) }
        #expect(MySQLColumnOrigins.origin(of: recursive, encoding: .utf8) == nil)
    }

    // Measured on MySQL 8.4.13 and MariaDB 13.0.2: each carried an e-mail address read from a user table.
    @Test("A system schema's column is never vouched for, only a user table's", arguments: [
        ("performance_schema", "events_statements_history", "MESSAGE_TEXT"),
        ("performance_schema", "data_locks", "LOCK_DATA"),
        ("performance_schema", "user_variables_by_thread", "VARIABLE_VALUE"),
        ("information_schema", "INNODB_LOCKS", "lock_data"),
        ("INFORMATION_SCHEMA", "COLUMN_STATISTICS", "HISTOGRAM"),
        ("information_schema", "OPTIMIZER_TRACE", "TRACE"),
        ("mysql", "column_stats", "max_value"),
        ("sys", "x$innodb_lock_waits", "locked_index"),
    ])
    func systemSchemasHaveNoOrigin(schema: String, table: String, column: String) {
        let field = Self.field(db: schema, table: table, column: column)
        defer { Self.release(field) }
        #expect(MySQLColumnOrigins.origin(of: field, encoding: .utf8) == nil)
    }

    @Test("Only MySQL and MariaDB, whose field names were measured, report origins")
    func onlyMeasuredFlavorsReportOrigins() {
        var traced = Self.field(db: "shop", table: "users", column: "email")
        defer { Self.release(traced) }
        let email: [PluginColumnOrigin?] = [PluginColumnOrigin(schema: "shop", table: "users", column: "email")]

        let mysql = Self.origins(of: &traced, flavor: .mysql)
        let mariadb = Self.origins(of: &traced, flavor: .mariadb)
        let starrocks = Self.origins(of: &traced, flavor: .starrocks)
        let databend = Self.origins(of: &traced, flavor: .databend)

        #expect(mysql == email)
        #expect(mariadb == email)
        #expect(starrocks == nil)
        #expect(databend == nil)
    }

    // A browse writes filter values as literals, so `'union'` in one used to read as "no origins", which a browse
    // takes as proof by name.
    @Test("A statement the scan distrusts leaves every column untrusted, never without origins")
    func distrustedStatementKeepsColumnsUntrusted() {
        var traced = Self.field(db: "shop", table: "users", column: "email")
        defer { Self.release(traced) }

        let filtered = Self.origins(of: &traced, flavor: .mysql, statement: "SELECT email FROM users WHERE name = 'union'")

        #expect(filtered == [nil])
    }

    private static func origins(
        of field: inout MYSQL_FIELD,
        flavor: MySQLServerFlavor,
        statement: String = "SELECT email AS e FROM users"
    ) -> [PluginColumnOrigin?]? {
        withUnsafeMutablePointer(to: &field) { pointer in
            MySQLColumnOrigins.origins(of: pointer, count: 1, encoding: .utf8, flavor: flavor, statement: statement)
        }
    }

    private static func field(db: String, table: String, column: String) -> MYSQL_FIELD {
        var field = MYSQL_FIELD()
        field.db = strdup(db)
        field.db_length = UInt32(db.utf8.count)
        field.org_table = strdup(table)
        field.org_table_length = UInt32(table.utf8.count)
        field.org_name = strdup(column)
        field.org_name_length = UInt32(column.utf8.count)
        return field
    }

    private static func release(_ field: MYSQL_FIELD) {
        free(field.db)
        free(field.org_table)
        free(field.org_name)
    }
}
