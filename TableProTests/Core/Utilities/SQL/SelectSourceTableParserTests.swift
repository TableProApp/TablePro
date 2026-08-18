//
//  SelectSourceTableParserTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("SelectSourceTableParser")
struct SelectSourceTableParserTests {
    private func table(_ sql: String, _ dialect: SqlDialect = .postgres) -> String? {
        guard let source = SelectSourceTableParser.singleSourceTable(in: sql, dialect: dialect) else {
            return nil
        }
        return source.schema == nil ? source.name : nil
    }

    private func source(
        _ sql: String,
        _ dialect: SqlDialect = .postgres
    ) -> SelectSourceTableParser.SourceTable? {
        SelectSourceTableParser.singleSourceTable(in: sql, dialect: dialect)
    }

    // MARK: - Table aliases (#2150)

    @Test("An implicit table alias resolves to the table")
    func implicitAlias() {
        #expect(table("select * from users u WHERE u.id = 1;") == "users")
        #expect(table("select * from users u WHERE u.id = 1") == "users")
        #expect(table("SELECT * FROM users u") == "users")
        #expect(table("SELECT u.* FROM users u") == "users")
        #expect(table("SELECT * FROM users u1 WHERE u1.id = 1") == "users")
    }

    @Test("An AS alias resolves to the table")
    func explicitAlias() {
        #expect(table("SELECT * FROM users AS u WHERE u.id = 1") == "users")
        #expect(table("SELECT * FROM users AS u;") == "users")
        #expect(table("SELECT * FROM users AS \"u\" WHERE 1") == "users")
        #expect(table("SELECT id FROM [Users] AS [u]") == "Users")
    }

    @Test("An alias is resolved after every clause keyword")
    func aliasBeforeClauses() {
        #expect(table("SELECT * FROM users u ORDER BY u.id") == "users")
        #expect(table("SELECT * FROM users u LIMIT 10 OFFSET 5") == "users")
        #expect(table("SELECT count(*) FROM users u GROUP BY u.id") == "users")
        #expect(table("SELECT * FROM users u WINDOW w AS ()") == "users")
        #expect(table("SELECT count(*) FROM users u HAVING count(*) > 1") == "users")
        #expect(table("SELECT * FROM users u FETCH FIRST 10 ROWS ONLY") == "users")
        #expect(table("SELECT * FROM users u OFFSET 5") == "users")
        #expect(table("SELECT * FROM users u QUALIFY row_number() OVER () = 1", .generic) == "users")
    }

    @Test("A quoted table keeps resolving when an alias follows it")
    func quotedTableWithAlias() {
        #expect(table("SELECT * FROM \"users\" u WHERE u.id = 1") == "users")
        #expect(table("SELECT * FROM `users` u WHERE u.id = 1") == "users")
        #expect(table("SELECT id FROM [Users] u WHERE u.id = 1") == "Users")
        #expect(table("SELECT * FROM users \"the alias\" WHERE 1") == "users")
    }

    @Test("A clause keyword is never mistaken for an alias")
    func clauseKeywordIsNotAnAlias() {
        #expect(table("select * from users where id = 1") == "users")
        #expect(table("SELECT * FROM users order by id") == "users")
        #expect(table("SELECT * FROM users group by id") == "users")
        #expect(table("SELECT * FROM users whereabouts") == "users")
        #expect(table("SELECT * FROM users_where WHERE id = 1") == "users_where")
    }

    // MARK: - Multi-source statements stay read-only

    @Test("A join never resolves, with or without aliases")
    func joinsAreNotSingleSource() {
        #expect(table("SELECT * FROM users JOIN orders ON orders.user_id = users.id") == nil)
        #expect(table("SELECT * FROM users u JOIN orders o ON o.user_id = u.id") == nil)
        #expect(table("SELECT * FROM users u LEFT JOIN orders o ON 1=1") == nil)
        #expect(table("SELECT * FROM users NATURAL JOIN orders") == nil)
        #expect(table("SELECT * FROM users u CROSS JOIN orders") == nil)
        #expect(table("SELECT * FROM users, orders WHERE users.id = orders.user_id") == nil)
        #expect(table("SELECT * FROM users u, orders o WHERE 1") == nil)
    }

    /// The regex this replaced returned the *second* branch's table here, which made a union grid
    /// editable and pointed its UPDATE at a table the rows did not come from.
    @Test("A set operator never resolves, wherever it appears")
    func setOperatorsAreNotSingleSource() {
        #expect(table("SELECT * FROM users UNION SELECT * FROM admins") == nil)
        #expect(table("SELECT * FROM users UNION ALL SELECT * FROM admins") == nil)
        #expect(table("SELECT * FROM users EXCEPT SELECT * FROM admins") == nil)
        #expect(table("SELECT * FROM users u INTERSECT SELECT * FROM admins") == nil)
        #expect(table("SELECT id FROM emp e WHERE 1=1 MINUS SELECT id FROM ex_emp x", .generic) == nil)
    }

    @Test("A set operator after a clause in the first branch still blocks editing")
    func setOperatorAfterFirstBranchClause() {
        #expect(table("SELECT * FROM a WHERE x = 1 UNION SELECT * FROM b") == nil)
        #expect(table("SELECT * FROM users u WHERE u.id > 0 UNION SELECT * FROM admins a WHERE a.id > 0") == nil)
        #expect(table("SELECT dept FROM employees e GROUP BY dept INTERSECT SELECT dept FROM contractors c GROUP BY dept") == nil)
        #expect(table("SELECT * FROM a u ORDER BY 1 UNION SELECT * FROM b") == nil)
        #expect(table("SELECT * FROM a u LIMIT 1 UNION SELECT * FROM b") == nil)
        #expect(table("SELECT *\nFROM live_orders o\nWHERE o.status='open'\nUNION ALL\nSELECT *\nFROM archive_orders a\nWHERE a.status='open'") == nil)
    }

    @Test("A set operator inside a subquery or a literal does not block editing")
    func setOperatorBelowTopLevel() {
        #expect(table("SELECT * FROM users u WHERE u.id IN (SELECT id FROM a UNION SELECT id FROM b)") == "users")
        #expect(table("SELECT * FROM users u WHERE u.name = 'UNION'") == "users")
        #expect(table("SELECT * FROM users u WHERE u.union_flag = 1") == "users")
    }

    @Test("Derived tables and CTEs never resolve")
    func derivedSourcesAreNotSingleSource() {
        #expect(table("SELECT * FROM (SELECT * FROM users) sub") == nil)
        #expect(table("WITH recent AS (SELECT * FROM users) SELECT * FROM recent") == nil)
        #expect(table("SELECT * FROM LATERAL (SELECT 1) x") == nil)
    }

    @Test("A schema-qualified source resolves to both parts")
    func qualifiedSourcesReportSchema() {
        #expect(source("SELECT * FROM public.users WHERE id = 1")
            == .init(schema: "public", name: "users"))
        #expect(source("SELECT * FROM public.users u WHERE u.id = 1")
            == .init(schema: "public", name: "users"))
        #expect(source("SELECT * FROM \"public\".\"users\" u")
            == .init(schema: "public", name: "users"))
        #expect(source("SELECT * FROM `db`.`orders` o WHERE 1", .mysql)
            == .init(schema: "db", name: "orders"))
        #expect(source("SELECT id FROM [dbo].[Users] AS [u]", .generic)
            == .init(schema: "dbo", name: "Users"))
        #expect(source("SELECT * FROM analytics.\"user events\" e WHERE 1")
            == .init(schema: "analytics", name: "user events"))
    }

    @Test("An unqualified source reports no schema")
    func unqualifiedSourcesReportNoSchema() {
        #expect(source("SELECT * FROM users u WHERE u.id = 1")
            == .init(schema: nil, name: "users"))
        #expect(source("SELECT * FROM \"public.user\"")
            == .init(schema: nil, name: "public.user"))
    }

    /// The write path can express one qualifier. Dropping the catalog would aim the statement at
    /// the connected database rather than the one the query named.
    @Test("A three-part catalog.schema.table never resolves")
    func catalogQualifiedNeverResolves() {
        #expect(source("SELECT * FROM db.public.users") == nil)
        #expect(source("SELECT * FROM \"db\".\"public\".\"users\" u") == nil)
    }

    // MARK: - Row locking versus result-shaping FOR clauses

    @Test("FOR UPDATE and its relatives keep the table editable")
    func rowLockingClauses() {
        #expect(table("SELECT * FROM users u FOR UPDATE") == "users")
        #expect(table("SELECT * FROM users u FOR NO KEY UPDATE") == "users")
        #expect(table("SELECT * FROM users u FOR SHARE") == "users")
        #expect(table("SELECT * FROM users u FOR UPDATE OF users") == "users")
    }

    /// A temporal read returns historical row versions, so an edit would overwrite the current row.
    @Test("FOR SYSTEM_TIME, FOR JSON and FOR XML stay read-only")
    func resultShapingForClauses() {
        #expect(table("SELECT * FROM t FOR SYSTEM_TIME AS OF '2020-01-01'", .mysql) == nil)
        #expect(table("SELECT * FROM t FOR SYSTEM_TIME ALL", .mysql) == nil)
        #expect(table("SELECT * FROM t FOR SYSTEM_TIME AS OF '2020' AS h WHERE h.id = 1", .mysql) == nil)
        #expect(table("SELECT * FROM users u FOR JSON AUTO", .generic) == nil)
        #expect(table("SELECT * FROM users u FOR XML PATH('r')", .generic) == nil)
    }

    // MARK: - Comments, literals and layout

    @Test("Comments around the statement do not hide the table")
    func comments() {
        #expect(table("-- pick users\nSELECT * FROM users u WHERE u.id = 1") == "users")
        #expect(table("/* pick */ SELECT * FROM users WHERE id = 1") == "users")
        #expect(table("SELECT * FROM users u -- trailing") == "users")
        #expect(table("SELECT * /* c */ FROM users u WHERE 1") == "users")
        #expect(table("SELECT * FROM users/*c*/WHERE 1") == "users")
    }

    @Test("A line comment ends at a lone carriage return")
    func carriageReturnEndsLineComment() {
        #expect(table("SELECT * FROM users u -- note\rJOIN orders o ON o.uid = u.id WHERE 1") == nil)
    }

    @Test("Whitespace and line endings do not hide the table")
    func layout() {
        #expect(table("SELECT *\nFROM users u\nWHERE u.id = 1") == "users")
        #expect(table("SELECT\n  id,\n  name\nFROM users") == "users")
        #expect(table("SELECT *\r\nFROM users u\r\nWHERE u.id = 1") == "users")
        #expect(table("SELECT *\tFROM users\tu\tWHERE u.id = 1") == "users")
        #expect(table("SELECT*FROM t") == "t")
        #expect(table("SELECTX FROM t") == nil)
    }

    @Test("A FROM inside a string literal is not the source table")
    func stringLiterals() {
        #expect(table("SELECT 'from x' FROM users u WHERE u.id = 1") == "users")
        #expect(table("SELECT ';' FROM users u WHERE 1") == "users")
        #expect(table("SELECT (SELECT 1 FROM a) FROM b WHERE 1") == "b")
    }

    // MARK: - Dialect-specific lexing

    @Test("A dollar-quoted body hides its FROM on PostgreSQL only")
    func dollarQuoting() {
        #expect(table("SELECT $$ FROM evil $$ FROM users") == "users")
        #expect(table("SELECT $tag$ FROM evil $tag$ AS c FROM users u WHERE 1") == "users")
        #expect(table("SELECT * FROM users u WHERE u.id = $1") == "users")
        #expect(table("SELECT $$ FROM evil FROM users") == nil)
        #expect(table("SELECT $price$ FROM products WHERE id = 1", .mysql) == "products")
        #expect(table("SELECT $tag$ AS a FROM t1 x WHERE 1", .sqlite) == "t1")
    }

    /// DuckDB accepts PostgreSQL's dollar quoting but maps to `.sqlite`, so a closed body on any
    /// other dialect means the text cannot be lexed as SQL and must not resolve.
    @Test("A closed dollar-quoted body off PostgreSQL blocks editing")
    func dollarQuotingOffPostgres() {
        let snippet = "SELECT $$SELECT * FROM audit_log a WHERE a.id=1$$ AS snippet FROM queries q WHERE q.id = 1"
        #expect(table(snippet, .sqlite) == nil)
        #expect(table("SELECT $sql$SELECT x FROM audit_log a WHERE 1$sql$ AS s FROM queries q WHERE 1", .sqlite) == nil)
    }

    @Test("# is a comment on MySQL and an operator on PostgreSQL")
    func hashHandling() {
        #expect(table("SELECT * # FROM evil\nFROM users", .mysql) == "users")
        #expect(table("SELECT * FROM users u # note", .mysql) == "users")
        #expect(table("SELECT id, data #>> '{name}' AS name FROM users WHERE id = 1") == "users")
        #expect(table("SELECT data #> '{a}' FROM events e WHERE 1") == "events")
    }

    /// ClickHouse spells line comments `#` and `//` and lands in `.generic`, which it shares with
    /// dialects that read both as operators. Guessing wrong would hide the real `FROM`.
    @Test("A generic-dialect # or // blocks editing rather than being guessed")
    func genericHashAndSlashComments() {
        #expect(table("SELECT *\n# read FROM users_v2 where possible\nFROM users u WHERE u.id = 1", .generic) == nil)
        #expect(table("SELECT *\n// read FROM users_v2\nFROM users u WHERE u.id = 1", .generic) == nil)
        #expect(table("SELECT a # b FROM t WHERE 1", .generic) == nil)
    }

    @Test("A backslash escapes a quote on MySQL and in a PostgreSQL E-string only")
    func backslashEscaping() {
        #expect(table("SELECT '\\' AS a, 'FROM evil e WHERE' AS b FROM notes n WHERE n.id = 1", .sqlite) == "notes")
        #expect(table("SELECT '\\' AS a, 'FROM evil e WHERE' AS b FROM notes n WHERE n.id = 1") == "notes")
        #expect(table("SELECT 'it\\'s' FROM users u WHERE 1", .mysql) == "users")
        #expect(table("SELECT E'it\\'s' FROM users u") == "users")
    }

    @Test("Block comments nest on PostgreSQL only")
    func blockCommentNesting() {
        #expect(table("SELECT * /* a /* b */ FROM evil */ FROM users") == "users")
        #expect(table("SELECT * /* a /* b */ FROM users", .mysql) == "users")
        #expect(table("SELECT /* a /* b */ x, '*/ FROM evil e WHERE' AS c FROM users u WHERE 1", .mysql) == "users")
    }

    // MARK: - Identifiers

    /// A generated write carries no `ONLY`, so it would reach the inheritance children the query
    /// excluded. On a dialect without the modifier the same text is a table named `only` wearing an
    /// alias, and reading it as a modifier would return the alias as the write target.
    @Test("FROM ONLY never resolves, on any dialect")
    func onlyModifierNeverResolves() {
        #expect(table("SELECT * FROM ONLY users") == nil)
        #expect(table("SELECT * FROM ONLY users u WHERE 1") == nil)
        #expect(table("SELECT * FROM ONLY accounts WHERE id = 5") == nil)
        #expect(table("SELECT * FROM ONLY users JOIN o ON 1=1") == nil)
        #expect(table("SELECT * FROM only orders WHERE id = 1", .mysql) == nil)
        #expect(table("SELECT * FROM only o WHERE o.id = 1", .sqlite) == nil)
    }

    @Test("A table genuinely named only still resolves")
    func tableNamedOnly() {
        #expect(table("SELECT * FROM only WHERE id = 1", .mysql) == "only")
        #expect(table("SELECT * FROM ONLY") == "ONLY")
        #expect(table("SELECT * FROM ONLY LIMIT 5") == "ONLY")
    }

    /// MySQL reads `"` as a string with backslash escapes, not as a delimited identifier. Getting
    /// that wrong shifts every later token and can hide a `UNION` from the multi-source check.
    @Test("A MySQL double-quoted string is not read as an identifier")
    func mysqlDoubleQuotedStrings() {
        #expect(table(#"SELECT "a\"b" AS x, "FROM evil e WHERE" AS y FROM notes n WHERE n.id = 1"#, .mysql) == "notes")
        #expect(table(#"SELECT * FROM parts WHERE label = "6\" pipe" UNION SELECT * FROM archive_parts"#, .mysql) == nil)
        #expect(table(#"SELECT * FROM a WHERE x = CONCAT("q\"(", y) UNION SELECT * FROM b"#, .mysql) == nil)
        #expect(table("SELECT * FROM \"users\" u", .mysql) == "users")
    }

    /// `[` is an array subscript on PostgreSQL, DuckDB and ClickHouse, and only a quoting character
    /// where the table reference itself sits.
    @Test("A bracket subscript in the select list is not an identifier")
    func bracketSubscripts() {
        #expect(table("SELECT a[strpos(b, ']')] FROM t WHERE 1") == "t")
        #expect(table("SELECT id, ARRAY[tags[1]] AS f FROM orders WHERE id=1") == "orders")
        #expect(table("SELECT a[strpos(b, ']')] AS c, ' FROM evil e WHERE' AS d FROM t WHERE 1") == "t")
        #expect(table("SELECT * FROM t WHERE arr[idx(arr,']')]>1 UNION SELECT * FROM evil") == nil)
        #expect(table("SELECT id FROM [Users] AS [u]", .generic) == "Users")
    }

    /// MINUS is a set operator only where Oracle, Snowflake and Teradata land. Elsewhere it is an
    /// ordinary column name.
    @Test("MINUS is a set operator only on the generic dialect")
    func minusIsDialectSpecific() {
        #expect(table("SELECT * FROM ledger ORDER BY minus") == "ledger")
        #expect(table("SELECT * FROM ledger l WHERE l.minus > 0") == "ledger")
        #expect(table("SELECT * FROM ledger GROUP BY minus", .mysql) == "ledger")
        #expect(table("SELECT * FROM a MINUS SELECT * FROM b", .generic) == nil)
    }

    @Test("Identifier spelling is preserved and delimiters are unescaped")
    func identifierSpelling() {
        #expect(table("SELECT * FROM USERS AS U") == "USERS")
        #expect(table("SELECT * FROM \"public.user\"") == "public.user")
        #expect(table("SELECT * FROM \"us\"\"ers\" u") == "us\"ers")
        #expect(table("SELECT * FROM `User Logs`") == "User Logs")
        #expect(table("SELECT * FROM my$table WHERE id = 1") == "my$table")
        #expect(table("SELECT * FROM benutzer ü WHERE 1") == "benutzer")
    }

    @Test("A statement that is not a single-table SELECT never resolves")
    func nonSelectStatements() {
        #expect(table("SELECT 1") == nil)
        #expect(table("INSERT INTO users VALUES (1)") == nil)
        #expect(table("UPDATE users SET x = 1") == nil)
        #expect(table("DELETE FROM users") == nil)
        #expect(table("SHOW TABLES") == nil)
        #expect(table("CREATE TABLE foo (id INT)") == nil)
        #expect(table("EXPLAIN SELECT * FROM users") == nil)
        #expect(table("") == nil)
        #expect(table("hello world this is not a query") == nil)
        #expect(table("db.users.find({})") == nil)
    }

    @Test("An unterminated delimiter or a table modifier never resolves")
    func unterminatedAndModified() {
        #expect(table("SELECT * FROM \"users") == nil)
        #expect(table("SELECT id FROM [Users") == nil)
        #expect(table("SELECT * FROM /* users") == nil)
        #expect(table("SELECT * FROM") == nil)
        #expect(table("SELECT * FROM users AS") == nil)
        #expect(table("SELECT * FROM users TABLESAMPLE BERNOULLI (10)") == nil)
        #expect(table("SELECT * FROM users u USE INDEX (i) WHERE 1", .mysql) == nil)
        #expect(table("SELECT 1; SELECT * FROM users") == nil)
    }
}
