//
//  SQLFormatterServiceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar
@testable import TablePro
import Testing

@MainActor
struct SQLFormatterServiceTests {
    let formatter = SQLFormatterService()

    private func format(_ sql: String, options: SQLFormatterOptions = .default) throws -> String {
        try formatter.format(sql, dialect: .mysql, options: options).formattedSQL
    }

    private func options(_ change: (inout SQLFormatterOptions) -> Void) -> SQLFormatterOptions {
        var options = SQLFormatterOptions.default
        change(&options)
        return options
    }

    private func expectFormat(
        _ sql: String,
        dialect: DatabaseType = .mysql,
        options: SQLFormatterOptions = .default,
        equals expected: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let first = try formatter.format(sql, dialect: dialect, options: options).formattedSQL
        #expect(first == expected, sourceLocation: sourceLocation)
        let second = try formatter.format(first, dialect: dialect, options: options).formattedSQL
        #expect(second == first, "a second pass changes the output", sourceLocation: sourceLocation)
    }

    // MARK: - Simple SELECT

    @Test("Simple SELECT *")
    func simpleSelectStar() throws {
        let result = try format("select * from users")
        #expect(result == """
        SELECT *
        FROM users
        """)
    }

    @Test("SELECT with multiple columns — each on its own line")
    func selectMultipleColumns() throws {
        let result = try format("select id, name, email from users")
        #expect(result == """
        SELECT id,
               name,
               email
        FROM users
        """)
    }

    @Test("SELECT with single column")
    func selectSingleColumn() throws {
        let result = try format("select id from users")
        #expect(result == """
        SELECT id
        FROM users
        """)
    }

    // MARK: - WHERE Clause

    @Test("Simple WHERE")
    func simpleWhere() throws {
        let result = try format("select * from users where active = true")
        #expect(result == """
        SELECT *
        FROM users
        WHERE active = TRUE
        """)
    }

    @Test("WHERE with AND/OR — each condition on new line")
    func whereWithAndOr() throws {
        let result = try format("select * from users where active = true and role = 'admin' or age > 18")
        #expect(result == """
        SELECT *
        FROM users
        WHERE active = TRUE
          AND role = 'admin'
          OR age > 18
        """)
    }

    // MARK: - ORDER BY / GROUP BY / HAVING / LIMIT

    @Test("ORDER BY on new line")
    func orderBy() throws {
        let result = try format("select * from users where id > 1 order by name asc limit 10")
        #expect(result == """
        SELECT *
        FROM users
        WHERE id > 1
        ORDER BY name ASC
        LIMIT 10
        """)
    }

    @Test("GROUP BY and HAVING")
    func groupByHaving() throws {
        let result = try format("select role, count(*) from users group by role having count(*) > 5")
        #expect(result == """
        SELECT role,
               count(*)
        FROM users
        GROUP BY role
        HAVING count(*) > 5
        """)
    }

    // MARK: - JOINs

    @Test("LEFT JOIN with ON")
    func leftJoin() throws {
        let result = try format("select u.id, r.name from users u left join roles r on u.role_id = r.id")
        #expect(result == """
        SELECT u.id,
               r.name
        FROM users u
        LEFT JOIN roles r
          ON u.role_id = r.id
        """)
    }

    @Test("Multiple JOINs")
    func multipleJoins() throws {
        let result = try format("select * from users u inner join roles r on u.role_id = r.id left join teams t on u.team_id = t.id")
        #expect(result == """
        SELECT *
        FROM users u
        INNER JOIN roles r
          ON u.role_id = r.id
        LEFT JOIN teams t
          ON u.team_id = t.id
        """)
    }

    // MARK: - Subqueries

    @Test("Subquery in FROM")
    func subqueryInFrom() throws {
        let result = try format("select * from (select id, name from users where active = true) as active_users")
        #expect(result == """
        SELECT *
        FROM (
          SELECT id,
                 name
          FROM users
          WHERE active = TRUE
        ) AS active_users
        """)
    }

    @Test("Subquery in WHERE")
    func subqueryInWhere() throws {
        let result = try format("select * from users where id in (select user_id from orders)")
        #expect(result == """
        SELECT *
        FROM users
        WHERE id IN (
          SELECT user_id
          FROM orders
        )
        """)
    }

    // MARK: - CASE WHEN

    @Test("CASE WHEN THEN ELSE END")
    func caseExpression() throws {
        let result = try format("select id, case when status = 'active' then 'yes' when status = 'inactive' then 'no' else 'unknown' end as label from users")
        #expect(result == """
        SELECT id,
               CASE
                 WHEN status = 'active' THEN 'yes'
                 WHEN status = 'inactive' THEN 'no'
                 ELSE 'unknown'
               END AS label
        FROM users
        """)
    }

    // MARK: - CTE (WITH)

    @Test("WITH / CTE")
    func cte() throws {
        let result = try format("with active_users as (select * from users where active = true) select * from active_users")
        #expect(result == """
        WITH active_users AS (
          SELECT *
          FROM users
          WHERE active = TRUE
        )
        SELECT *
        FROM active_users
        """)
    }

    // MARK: - UNION / INTERSECT / EXCEPT

    @Test("UNION between SELECT statements")
    func union() throws {
        let result = try format("select id from users union all select id from admins")
        #expect(result == """
        SELECT id
        FROM users

        UNION ALL

        SELECT id
        FROM admins
        """)
    }

    // MARK: - INSERT

    @Test("INSERT INTO VALUES")
    func insertValues() throws {
        let result = try format("insert into users (id, name, email) values (1, 'John', 'john@test.com')")
        #expect(result == """
        INSERT INTO users (id, name, email)
        VALUES (1, 'John', 'john@test.com')
        """)
    }

    // MARK: - UPDATE

    @Test("UPDATE SET WHERE")
    func updateSetWhere() throws {
        let result = try format("update users set name = 'John', email = 'john@test.com' where id = 1")
        #expect(result == """
        UPDATE users
        SET name = 'John',
            email = 'john@test.com'
        WHERE id = 1
        """)
    }

    // MARK: - DELETE

    @Test("DELETE FROM WHERE")
    func deleteFromWhere() throws {
        let result = try format("delete from users where active = false")
        #expect(result == """
        DELETE
        FROM users
        WHERE active = FALSE
        """)
    }

    // MARK: - CREATE TABLE

    @Test("CREATE TABLE with columns")
    func createTable() throws {
        let result = try format("create table users (id int primary key, name varchar(255) not null, email varchar(255))")
        #expect(result == """
        CREATE TABLE users (
          id int PRIMARY KEY,
          name varchar(255) NOT NULL,
          email varchar(255)
        )
        """)
    }

    // MARK: - Multiple Statements

    @Test("Multiple statements — no blank line when input has none")
    func multipleStatementsCompact() throws {
        let result = try format("select 1; select 2;")
        #expect(result == """
        SELECT 1;
        SELECT 2;
        """)
    }

    @Test("Multiple statements — preserves blank line from input")
    func multipleStatementsWithBlankLine() throws {
        let result = try format("select 1;\n\nselect 2;")
        #expect(result == """
        SELECT 1;

        SELECT 2;
        """)
    }

    @Test("Multiple statements — caps excessive blank lines to 2")
    func multipleStatementsCapped() throws {
        let result = try format("select 1;\n\n\n\n\nselect 2;")
        #expect(result == """
        SELECT 1;


        SELECT 2;
        """)
    }

    // MARK: - Comments

    @Test("Line comment preserved")
    func lineCommentPreserved() throws {
        let result = try format("-- fetch users\nselect * from users")
        #expect(result == """
        -- fetch users
        SELECT *
        FROM users
        """)
    }

    @Test("Block comment preserved")
    func blockCommentPreserved() throws {
        let result = try format("/* all users */ select * from users")
        #expect(result == """
        /* all users */
        SELECT *
        FROM users
        """)
    }

    // MARK: - String Preservation

    @Test("String literals are not uppercased")
    func stringPreservation() throws {
        let result = try format("select 'hello world' from users")
        #expect(result.contains("'hello world'"))
        #expect(!result.contains("'HELLO WORLD'"))
    }

    // MARK: - Keyword Uppercasing

    @Test("Keywords are uppercased by default")
    func keywordUppercasing() throws {
        let result = try format("select * from users where id = 1")
        #expect(result.contains("SELECT"))
        #expect(result.contains("FROM"))
        #expect(result.contains("WHERE"))
    }

    @Test("Keywords not uppercased when option is false")
    func keywordsNotUppercased() throws {
        var options = SQLFormatterOptions.default
        options.keywordCase = .preserve
        let result = try format("select * from users", options: options)
        #expect(result.contains("select"))
        #expect(result.contains("from"))
    }

    // MARK: - Idempotency

    @Test("Formatting twice gives same result")
    func idempotency() throws {
        let sql = "select id, name from users where active = true and role = 'admin' order by name"
        let first = try format(sql)
        let second = try format(first)
        #expect(first == second)
    }

    // MARK: - Error Handling

    @Test("Empty input throws")
    func emptyInputThrows() {
        #expect(throws: SQLFormatterError.self) {
            try format("")
        }
    }

    @Test("Whitespace-only input throws")
    func whitespaceOnlyThrows() {
        #expect(throws: SQLFormatterError.self) {
            try format("   \n\t  ")
        }
    }

    @Test("Invalid cursor position throws")
    func invalidCursorThrows() {
        #expect(throws: SQLFormatterError.self) {
            try formatter.format("select 1", dialect: .mysql, cursorOffset: 1000)
        }
    }

    @Test("Size limit throws")
    func sizeLimitThrows() {
        let large = String(repeating: "select 1; ", count: 1_100_000)
        #expect(throws: SQLFormatterError.self) {
            try format(large)
        }
    }

    // MARK: - Cursor Preservation

    @Test("Cursor offset preserved when provided")
    func cursorPreserved() throws {
        let result = try formatter.format("select * from users", dialect: .mysql, cursorOffset: 7)
        #expect(result.cursorOffset != nil)
    }

    @Test("No cursor returns nil")
    func noCursorReturnsNil() throws {
        let result = try formatter.format("select * from users", dialect: .mysql)
        #expect(result.cursorOffset == nil)
    }

    // MARK: - Edge Cases

    @Test("Trimmed output")
    func trimmedOutput() throws {
        let result = try format("   select * from users   ")
        #expect(result == result.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("SELECT with function calls")
    func selectWithFunctions() throws {
        let result = try format("select count(*), max(id) from users")
        #expect(result == """
        SELECT count(*),
               max(id)
        FROM users
        """)
    }

    @Test("DISTINCT keyword")
    func distinct() throws {
        let result = try format("select distinct name from users")
        #expect(result == """
        SELECT DISTINCT name
        FROM users
        """)
    }

    @Test("BETWEEN x AND y stays inline")
    func betweenAnd() throws {
        let result = try format("select * from users where id between 1 and 100 and active = true")
        #expect(result == """
        SELECT *
        FROM users
        WHERE id BETWEEN 1 AND 100
          AND active = TRUE
        """)
    }

    @Test("Window function OVER(PARTITION BY...ORDER BY) stays inline")
    func windowFunction() throws {
        let result = try format("select *, row_number() over (partition by department order by salary desc) as rank from employees")
        #expect(result == """
        SELECT *,
               row_number() OVER(PARTITION BY department ORDER BY salary DESC) AS rank
        FROM employees
        """)
    }

    // MARK: - Set Operations Inside Subqueries and CTEs

    @Test("UNION inside a derived table keeps nesting and closes on its own line")
    func unionInDerivedTable() throws {
        let sql = "select country, avg(score) as score "
            + "from (select yr, country, score from scores "
            + "union select 2024, country, ladder from scores_current) as final "
            + "group by country"
        let result = try format(sql)
        #expect(result == """
        SELECT country,
               avg(score) AS score
        FROM (
          SELECT yr,
                 country,
                 score
          FROM scores
          UNION
          SELECT 2024,
                 country,
                 ladder
          FROM scores_current
        ) AS final
        GROUP BY country
        """)
    }

    @Test("UNION ALL inside a derived table")
    func unionAllInDerivedTable() throws {
        let result = try format("select * from (select id from a union all select id from b) as t")
        #expect(result == """
        SELECT *
        FROM (
          SELECT id
          FROM a
          UNION ALL
          SELECT id
          FROM b
        ) AS t
        """)
    }

    @Test("INTERSECT inside a derived table")
    func intersectInDerivedTable() throws {
        let result = try format("select * from (select id from a intersect select id from b) as t")
        #expect(result == """
        SELECT *
        FROM (
          SELECT id
          FROM a
          INTERSECT
          SELECT id
          FROM b
        ) AS t
        """)
    }

    @Test("EXCEPT inside a derived table")
    func exceptInDerivedTable() throws {
        let result = try format("select * from (select id from a except select id from b) as t")
        #expect(result == """
        SELECT *
        FROM (
          SELECT id
          FROM a
          EXCEPT
          SELECT id
          FROM b
        ) AS t
        """)
    }

    @Test("MINUS inside a derived table (Oracle)")
    func minusInDerivedTable() throws {
        let result = try formatter.format(
            "select * from (select id from a minus select id from b) as t",
            dialect: .oracle
        ).formattedSQL
        #expect(result == """
        SELECT *
        FROM (
          SELECT id
          FROM a
          MINUS
          SELECT id
          FROM b
        ) AS t
        """)
    }

    @Test("UNION inside a CTE body")
    func unionInsideCTE() throws {
        let result = try format("with combined as (select id from a union select id from b) select * from combined")
        #expect(result == """
        WITH combined AS (
          SELECT id
          FROM a
          UNION
          SELECT id
          FROM b
        )
        SELECT *
        FROM combined
        """)
    }

    @Test("UNION inside a nested subquery keeps both levels")
    func unionInNestedSubquery() throws {
        let result = try format("select * from (select id from (select id from t union select id from u) as iq) as oq")
        #expect(result == """
        SELECT *
        FROM (
          SELECT id
          FROM (
            SELECT id
            FROM t
            UNION
            SELECT id
            FROM u
          ) AS iq
        ) AS oq
        """)
    }

    @Test("Chained top-level UNIONs keep blank-line separation")
    func chainedTopLevelUnions() throws {
        let result = try format("select 1 union select 2 union select 3")
        #expect(result == """
        SELECT 1

        UNION

        SELECT 2

        UNION

        SELECT 3
        """)
    }

    @Test("Top-level INTERSECT keeps blank-line separation")
    func topLevelIntersect() throws {
        let result = try format("select id from a intersect select id from b")
        #expect(result == """
        SELECT id
        FROM a

        INTERSECT

        SELECT id
        FROM b
        """)
    }

    @Test("INSERT ... SELECT")
    func insertSelect() throws {
        let result = try format("insert into t (a, b) select a, b from s")
        #expect(result == """
        INSERT INTO t (a, b)
        SELECT a,
               b
        FROM s
        """)
    }

    // MARK: - Idempotency of Nested Set Operations

    @Test("UNION in derived table is idempotent")
    func unionInDerivedTableIdempotent() throws {
        let sql = "select * from (select id from a union select id from b) as t"
        let first = try format(sql)
        let second = try format(first)
        #expect(first == second)
    }

    @Test("Nested subquery with UNION is idempotent")
    func nestedUnionIdempotent() throws {
        let sql = "select * from (select id from (select id from t union select id from u) as iq) as oq where id > 0"
        let first = try format(sql)
        let second = try format(first)
        #expect(first == second)
    }

    // MARK: - Unterminated Constructs

    @Test("Formats a query whose string literal is unterminated and ends in a backslash")
    func unterminatedLiteralEndingInBackslash() throws {
        let formatted = try format("select * from t where c like 'C:\\")
        #expect(formatted.contains("'C:\\"))
    }

    /// The editor closes a typed quote for the user, so a backtick is how this input reaches Format
    /// Query from the keyboard. It takes the same tokenizer branch.
    @Test("Formats a query whose backtick identifier is unterminated and ends in a backslash")
    func unterminatedBacktickEndingInBackslash() throws {
        let formatted = try format("select * from t where c like `C:\\")
        #expect(formatted.contains("SELECT"))
        #expect(formatted.contains("`C:\\"))
    }

    @Test("Formats a query whose block comment is unterminated")
    func unterminatedBlockComment() throws {
        let formatted = try format("select 1; /* note")
        #expect(formatted.hasSuffix("/* note"))
    }

    // MARK: - Expressions Inside Parentheses

    @Test("Commas inside a function call in the SELECT list stay inline")
    func functionArgumentsStayInline() throws {
        let result = try format("select concat(first_name, ' ', last_name) as name, id from users")
        #expect(result == """
        SELECT concat(first_name, ' ', last_name) AS name,
               id
        FROM users
        """)
    }

    @Test("FROM, WHERE and ORDER BY inside parentheses stay inline")
    func clauseKeywordsInsideParentheses() throws {
        let result = try format(
            "select substring(name from 2) as s, count(*) filter (where x > 0), "
                + "string_agg(name, ', ' order by name) from t"
        )
        #expect(result == """
        SELECT substring(name FROM 2) AS s,
               count(*) FILTER (WHERE x > 0),
               string_agg(name, ', ' ORDER BY name)
        FROM t
        """)
    }

    @Test("A column list keeps CHARACTER SET, WITH TIME ZONE and ON DELETE inline")
    func createTableColumnClauses() throws {
        let result = try format(
            "create table t (id int, ts timestamp with time zone, name text CHARACTER set utf8mb4, "
                + "parent int references p(id) on delete cascade)"
        )
        #expect(result == """
        CREATE TABLE t (
          id int,
          ts timestamp WITH time zone,
          name text CHARACTER SET utf8mb4,
          parent int REFERENCES p(id) ON DELETE CASCADE
        )
        """)
    }

    @Test("A keyword beside a dot is a name and keeps its spelling")
    func qualifiedNamesKeepSpelling() throws {
        let result = try format(
            "select e.end, t.key, dbo.count(x), count(*) from events e",
            options: options { $0.functionCase = .upper }
        )
        #expect(result == """
        SELECT e.end,
               t.key,
               dbo.count(x),
               COUNT(*)
        FROM events e
        """)
    }

    @Test("A statement keyword after the word it modifies stays in its clause")
    func statementKeywordsAsModifiers() throws {
        #expect(try format("select * from t where id = 1 for update") == """
        SELECT *
        FROM t
        WHERE id = 1 for UPDATE
        """)
        #expect(try format("insert into t (a) values (1) on DUPLICATE key update a = values(a)") == """
        INSERT INTO t (a)
        VALUES (1) ON DUPLICATE KEY UPDATE a = VALUES (a)
        """)
        #expect(try format("grant select, insert on t to u") == "GRANT SELECT, INSERT ON t to u")
    }

    @Test("A statement keyword after EXPLAIN starts its own line instead of joining it")
    func explainKeepsKeywordsApart() throws {
        #expect(try format("explain select * from t") == """
        EXPLAIN
        SELECT *
        FROM t
        """)
        #expect(try format("explain update t set a = 1") == """
        EXPLAIN
        UPDATE t
        SET a = 1
        """)
    }

    // MARK: - Indentation Options

    @Test("Indent width sets the step of every nested level")
    func indentWidth() throws {
        let result = try format(
            "select * from (select id from users where a = 1 and b = 2) as t",
            options: options { $0.indentWidth = 4 }
        )
        #expect(result == """
        SELECT *
        FROM (
            SELECT id
            FROM users
            WHERE a = 1
                AND b = 2
        ) AS t
        """)
    }

    @Test("Tab indentation puts tabs before the alignment spaces")
    func tabIndentation() throws {
        let result = try format(
            "select * from (select id, name from users) as t",
            options: options { $0.indentStyle = .tabs }
        )
        #expect(result == "SELECT *\nFROM (\n\tSELECT id,\n\t       name\n\tFROM users\n) AS t")
    }

    @Test("ON follows the indent width")
    func joinConditionIndent() throws {
        let result = try format(
            "select * from users u left join roles r on u.role_id = r.id",
            options: options { $0.indentWidth = 4 }
        )
        #expect(result == """
        SELECT *
        FROM users u
        LEFT JOIN roles r
            ON u.role_id = r.id
        """)
    }

    // MARK: - Case Options

    @Test("Keyword case lower writes keywords and synthesized words lower case")
    func keywordCaseLower() throws {
        let result = try format(
            "SELECT id FROM users LEFT JOIN roles ON 1 = 1 ORDER BY id",
            options: options { $0.keywordCase = .lower }
        )
        #expect(result == """
        select id
        from users
        left join roles
          on 1 = 1
        order by id
        """)
    }

    @Test("Function case rewrites a call and leaves a column with a function's name alone")
    func functionCase() throws {
        let upper = try format("select count(*), max(id), count from t", options: options { $0.functionCase = .upper })
        #expect(upper == """
        SELECT COUNT(*),
               MAX(id),
               count
        FROM t
        """)
        let lower = try format("select COUNT(*) from t", options: options { $0.functionCase = .lower })
        #expect(lower == """
        SELECT count(*)
        FROM t
        """)
    }

    @Test("Function case leaves calls alone where the engine matches function names by exact case")
    func functionCaseOnCaseSensitiveEngine() throws {
        var tokenFormatter = SQLTokenFormatter(
            options: options { $0.functionCase = .upper },
            dialectFunctions: ["toString"],
            rewritesFunctionCase: false
        )
        let tokens = SQLTokenizer(dialectKeywords: ["toString"]).tokenize("select toString(x), count(*) from t")
        #expect(tokenFormatter.format(tokens) == """
        SELECT toString(x),
               count(*)
        FROM t
        """)
    }

    // MARK: - Comma Position

    @Test("Leading commas line up the items of a SELECT list")
    func leadingCommasSelect() throws {
        let result = try format(
            "select id, name, email from users",
            options: options { $0.commaPosition = .leading }
        )
        #expect(result == """
        SELECT id
             , name
             , email
        FROM users
        """)
    }

    @Test("Leading commas in a SET list and a column list")
    func leadingCommasSetAndColumns() throws {
        let leading = options { $0.commaPosition = .leading }
        #expect(try format("update users set name = 'a', email = 'b' where id = 1", options: leading) == """
        UPDATE users
        SET name = 'a'
          , email = 'b'
        WHERE id = 1
        """)
        #expect(try format("create table t (id int, name text)", options: leading) == """
        CREATE TABLE t (
          id int
          , name text
        )
        """)
    }

    @Test("Leading commas leave a function call's arguments inline")
    func leadingCommasKeepArgumentsInline() throws {
        let result = try format("select concat(a, b), c from t", options: options { $0.commaPosition = .leading })
        #expect(result == """
        SELECT concat(a, b)
             , c
        FROM t
        """)
    }

    // MARK: - Line Width

    @Test("A list that fits the line width stays on one line")
    func lineWidthKeepsShortListsInline() throws {
        let result = try format(
            "select id, name from users where a = 1 and b = 2",
            options: options { $0.lineWidth = 40 }
        )
        #expect(result == """
        SELECT id, name
        FROM users
        WHERE a = 1 AND b = 2
        """)
    }

    @Test("A list longer than the line width breaks one item per line")
    func lineWidthBreaksLongLists() throws {
        let result = try format(
            "select first_column, second_column, third_column from t",
            options: options { $0.lineWidth = 40 }
        )
        #expect(result == """
        SELECT first_column,
               second_column,
               third_column
        FROM t
        """)
    }

    @Test("A line exactly at the width fits, one character more does not")
    func lineWidthBoundary() throws {
        let sql = "select aaaa, bbbb from t"
        #expect(try format(sql, options: options { $0.lineWidth = 17 }).hasPrefix("SELECT aaaa, bbbb\n"))
        #expect(try format(sql, options: options { $0.lineWidth = 16 }).hasPrefix("SELECT aaaa,\n"))
    }

    @Test("A list holding a subquery never stays on one line")
    func lineWidthBreaksAroundSubquery() throws {
        let result = try format(
            "select a, (select max(b) from u) as m from t",
            options: options { $0.lineWidth = 200 }
        )
        #expect(result.hasPrefix("SELECT a,\n"))
    }

    @Test("Line width applies to a nested SELECT on its own")
    func lineWidthNested() throws {
        let result = try format(
            "select * from (select id, name from users) as t",
            options: options { $0.lineWidth = 80 }
        )
        #expect(result == """
        SELECT *
        FROM (
          SELECT id, name
          FROM users
        ) AS t
        """)
    }

    // MARK: - Join Condition

    @Test("Join condition on the JOIN line")
    func joinConditionSameLine() throws {
        let result = try format(
            "select * from users u inner join roles r on u.role_id = r.id left join teams t on u.team_id = t.id",
            options: options { $0.joinCondition = .sameLine }
        )
        #expect(result == """
        SELECT *
        FROM users u
        INNER JOIN roles r ON u.role_id = r.id
        LEFT JOIN teams t ON u.team_id = t.id
        """)
    }

    // MARK: - Alias Alignment

    @Test("Aliases line up in one column")
    func alignAliases() throws {
        let result = try format(
            "select u.id as user_id, u.name as name, count(o.id) as order_count, u.email from users u",
            options: options { $0.alignAliases = true }
        )
        #expect(result == """
        SELECT u.id        AS user_id,
               u.name      AS name,
               count(o.id) AS order_count,
               u.email
        FROM users u
        """)
    }

    @Test("Alias alignment with leading commas")
    func alignAliasesLeadingCommas() throws {
        let result = try format(
            "select id as a, created_at as b from t",
            options: options {
                $0.alignAliases = true
                $0.commaPosition = .leading
            }
        )
        #expect(result == """
        SELECT id         AS a
             , created_at AS b
        FROM t
        """)
    }

    @Test("A column spanning lines and an AS inside a call are not aligned")
    func alignAliasesSkipsMultilineAndNested() throws {
        let result = try format(
            "select cast(x as int) as xi, case when a then 1 end as flag, id as identifier from t",
            options: options { $0.alignAliases = true }
        )
        #expect(result == """
        SELECT cast(x AS int) AS xi,
               CASE
                 WHEN a THEN 1
               END AS flag,
               id             AS identifier
        FROM t
        """)
    }

    // MARK: - Lexing, layout and options

    @Test("ORDER BY first in OVER keeps its space before the column")
    func windowOrderByFirst() throws {
        try expectFormat(
            "select row_number() over (order by id desc) as rn from t",
            equals: """
        SELECT row_number() OVER(ORDER BY id DESC) AS rn
        FROM t
        """
        )
    }

    @Test("Window frame ROWS BETWEEN stays inline")
    func windowFrameInline() throws {
        try expectFormat(
            "select sum(x) over (order by id rows between unbounded preceding and current row) as running from t",
            equals: """
        SELECT sum(x) OVER(ORDER BY id ROWS BETWEEN unbounded preceding AND current row) AS running
        FROM t
        """
        )
    }

    @Test("WITHIN GROUP keeps its ORDER BY inline and the SELECT list open")
    func withinGroupKeepsSelectList() throws {
        try expectFormat(
            "select percentile_cont(0.5) within group (order by salary) as p, dept from t group by dept",
            equals: """
        SELECT percentile_cont(0.5) within GROUP (ORDER BY salary) AS p,
               dept
        FROM t
        GROUP BY dept
        """
        )
    }

    @Test("A comment between a paren and SELECT opens the subquery on its own lines")
    func commentBeforeSubquerySelect() throws {
        let sql = """
        select * from t where id in (
          -- only active
          select id from u where active)
        """
        try expectFormat(
            sql,
            equals: """
        SELECT *
        FROM t
        WHERE id IN (
          -- only active
          SELECT id
          FROM u
          WHERE active
        )
        """
        )
    }

    @Test("A block comment between EXISTS ( and SELECT keeps SELECT apart from its column")
    func commentBeforeExistsSelect() throws {
        try expectFormat(
            "select * from t where exists (/* any */ select distinct id from u)",
            dialect: .postgresql,
            equals: """
        SELECT *
        FROM t
        WHERE EXISTS (
          /* any */
          SELECT DISTINCT id
          FROM u
        )
        """
        )
    }

    @Test("SQL Server bracket names keep their spelling and spaces")
    func bracketIdentifiers() throws {
        try expectFormat(
            "select [order id], [group] from [my table] where [select] = 1",
            dialect: .mssql,
            equals: """
        SELECT [order id],
               [group]
        FROM [my table]
        WHERE [select] = 1
        """
        )
    }

    @Test("A GO line stays a line of its own")
    func batchSeparatorLine() throws {
        let sql = """
        select 1
        GO
        select 2
        """
        try expectFormat(
            sql,
            dialect: .mssql,
            equals: """
        SELECT 1
        GO
        SELECT 2
        """
        )
    }

    @Test("T-SQL temp tables and variables stay one word")
    func tempTablesAndVariables() throws {
        try expectFormat(
            "select * from ##global where @@rowcount > 0 and x = @p and y in (select z from #tmp)",
            dialect: .mssql,
            equals: """
        SELECT *
        FROM ##global
        WHERE @@rowcount > 0
          AND x = @p
          AND y IN (
            SELECT z
            FROM #tmp
          )
        """
        )
    }

    @Test("A MySQL # comment ends at its line and the next condition stays code")
    func hashCommentEndsAtLine() throws {
        let sql = """
        select * from t where a = 1 # keep only a
        and b = 2
        """
        try expectFormat(
            sql,
            options: options { $0.lineWidth = 80 },
            equals: """
        SELECT *
        FROM t
        WHERE a = 1
        # keep only a
          AND b = 2
        """
        )
    }

    @Test("A dollar-quoted body is copied byte for byte")
    func dollarQuotedBodyVerbatim() throws {
        let sql = """
        CREATE FUNCTION f() RETURNS int AS $$
        if x:
            return 1
        return 2
        $$ LANGUAGE plpython3u;
        """
        try expectFormat(
            sql,
            dialect: .postgresql,
            options: options { $0.keywordCase = .preserve },
            equals: sql
        )
    }

    @Test("E'' keeps its prefix and a backslash in a plain PostgreSQL string ends nothing")
    func escapeStringPrefix() throws {
        try expectFormat(
            #"select E'a\'b' as s, 'C:\', 'hello   world' from t"#,
            dialect: .postgresql,
            equals: #"""
        SELECT E'a\'b' AS s,
               'C:\',
               'hello   world'
        FROM t
        """#
        )
    }

    @Test("Oracle q-quoted literal stays whole")
    func alternativeQuoting() throws {
        try expectFormat(
            "select q'[it's]' as s from dual",
            dialect: .oracle,
            equals: """
        SELECT q'[it's]' AS s
        FROM dual
        """
        )
    }

    @Test("A SQL*Plus slash line stays a line of its own")
    func sqlPlusSlashLine() throws {
        let sql = """
        create table t (a int)
        /
        select a / 2 from dual
        """
        try expectFormat(
            sql,
            dialect: .oracle,
            equals: """
        CREATE TABLE t (
          a int
        )
        /
        SELECT a / 2
        FROM dual
        """
        )
    }

    @Test("A MySQL DELIMITER block keeps its delimiter lines and terminator")
    func delimiterDirective() throws {
        let sql = """
        DELIMITER //
        create procedure p() begin select 1; end //
        DELIMITER ;
        select 2;
        """
        try expectFormat(
            sql,
            equals: """
        DELIMITER //
        CREATE procedure p() BEGIN
        SELECT 1;
        END //
        DELIMITER ;
        SELECT 2;
        """
        )
    }

    @Test("PostgreSQL operators stay whole")
    func postgresOperators() throws {
        try expectFormat(
            "select * from t where tags @> array['x'] and a <@ b and d ?| array['a'] and j #>> '{a}' = 'x' and s ~* 'x' and s !~ 'y' and v <=> '[1,2,3]' and p && q and make_interval(days => 10) > x",
            dialect: .postgresql,
            equals: """
        SELECT *
        FROM t
        WHERE tags @> array['x']
          AND a <@ b
          AND d ?| array['a']
          AND j #>> '{a}' = 'x'
          AND s ~* 'x'
          AND s !~ 'y'
          AND v <=> '[1,2,3]'
          AND p && q
          AND make_interval(days => 10) > x
        """
        )
    }

    @Test("MySQL system variables, assignment and null-safe equality stay whole")
    func mysqlOperators() throws {
        try expectFormat(
            "select @@version, @a := 1, a <=> b, c << 2 from t",
            equals: """
        SELECT @@version,
               @a := 1,
               a <=> b,
               c << 2
        FROM t
        """
        )
    }

    @Test("A literal prefix stays on its literal")
    func prefixedLiterals() throws {
        try expectFormat(
            "select 0xFF, flags & 0x04, N'abc', X'4D', B'101', _utf8mb4'a' from t",
            equals: """
        SELECT 0xFF,
               flags & 0x04,
               N'abc',
               X'4D',
               B'101',
               _utf8mb4'a'
        FROM t
        """
        )
    }

    @Test("A custom delimiter glued to the word before it still ends the statement")
    func customDelimiterEndsAGluedWord() throws {
        let procedure = """
        DELIMITER $$
        CREATE PROCEDURE p()
        BEGIN
          SELECT 1;
        END$$
        DELIMITER ;
        SELECT 2;
        """
        try expectFormat(
            procedure,
            equals: """
        DELIMITER $$
        CREATE PROCEDURE p() BEGIN
        SELECT 1;
        END $$
        DELIMITER ;
        SELECT 2;
        """
        )
        try expectFormat(
            "DELIMITER $$\nCREATE FUNCTION f() RETURNS INT DETERMINISTIC\nRETURN 1$$\nDELIMITER ;\nSELECT f();",
            equals: """
        DELIMITER $$
        CREATE FUNCTION f() RETURNS INT DETERMINISTIC RETURN 1 $$
        DELIMITER ;
        SELECT f();
        """
        )
    }

    @Test("Operators no dialect declares stay whole")
    func undeclaredOperatorsStayWhole() throws {
        try expectFormat(
            "SET @x += 1; SET @x -= 1; SET @x *= 2; SET @x /= 2; SET @x %= 2; SET @x &= 1; SET @x |= 1; SET @x ^= 1",
            dialect: .mssql,
            equals: """
        SET @x += 1;
        SET @x -= 1;
        SET @x *= 2;
        SET @x /= 2;
        SET @x %= 2;
        SET @x &= 1;
        SET @x |= 1;
        SET @x ^= 1
        """
        )
        for dialect in [DatabaseType.sqlite, .clickhouse] {
            try expectFormat("select * from t where a == b", dialect: dialect, equals: "SELECT *\nFROM t\nWHERE a == b")
        }
        try expectFormat(
            "select * from t where a ^= b and y ** 2 > 1 and c ~= d",
            dialect: .oracle,
            equals: """
        SELECT *
        FROM t
        WHERE a ^= b
          AND y ** 2 > 1
          AND c ~= d
        """
        )
        try expectFormat("select 7 // 2, 2 ** 3", dialect: .duckdb, equals: "SELECT 7 // 2,\n       2 ** 3")
    }

    @Test("A T-SQL name keeps a # or @ after its first character")
    func tsqlNamesKeepHashAndAt() throws {
        try expectFormat(
            "SELECT Part# FROM Parts; SELECT a#b, c@d FROM t WHERE @v@x = 1",
            dialect: .mssql,
            equals: """
        SELECT Part#
        FROM Parts;
        SELECT a#b,
               c@d
        FROM t
        WHERE @v@x = 1
        """
        )
    }

    @Test("Two string literals continued across a line break keep the break", arguments: [DatabaseType.postgresql, .duckdb])
    func stringContinuationKeepsItsLineBreak(dialect: DatabaseType) throws {
        try expectFormat(
            "select 'foo'\n'bar' as s, 'x' from t",
            dialect: dialect,
            equals: """
        SELECT 'foo'
               'bar' AS s,
               'x'
        FROM t
        """
        )
    }

    @Test("A keyword-named column before an operator or a subscript keeps its spelling")
    func keywordNamedColumnBeforeOperator() throws {
        try expectFormat(
            "SELECT table, rows + marks, key[1], rows::String, bytes - 1, bytes * 2 FROM system.parts",
            dialect: .clickhouse,
            equals: """
        SELECT table,
               rows + marks,
               key[1],
               rows :: String,
               bytes - 1,
               bytes * 2
        FROM system.parts
        """
        )
        try expectFormat(
            "select distinct * from t; select array[1, 2], tags[1] from t",
            dialect: .postgresql,
            equals: """
        SELECT DISTINCT *
        FROM t;
        SELECT array[1, 2],
               tags[1]
        FROM t
        """
        )
    }

    @Test("A word written against a quote stays against it, whether or not it introduces the literal")
    func wordAgainstQuoteStaysAgainstIt() throws {
        try expectFormat(
            "select r'abc', b'0101', a'alias' from t",
            equals: """
        SELECT r'abc',
               b'0101',
               a'alias'
        FROM t
        """
        )
    }

    @Test("U& and E prefixes stay on their literals")
    func unicodeEscapeLiteral() throws {
        try expectFormat(
            #"select U&'d\0061t' as u, E'x' from t"#,
            dialect: .postgresql,
            equals: #"""
        SELECT U&'d\0061t' AS u,
               E'x'
        FROM t
        """#
        )
    }

    @Test("OUTER APPLY and CROSS APPLY start their own lines and keep OUTER")
    func outerApply() throws {
        try expectFormat(
            "select * from a outer apply f(a.id) x cross apply g(a.id) y",
            dialect: .mssql,
            equals: """
        SELECT *
        FROM a
        OUTER APPLY f(a.id) x
        CROSS APPLY g(a.id) y
        """
        )
    }

    @Test("A CREATE VIEW's calls keep their parens")
    func createViewCallsKeepParens() throws {
        try expectFormat(
            "create view v as select id, count(*) as n from t group by id",
            equals: """
        CREATE VIEW v AS
        SELECT id,
               count(*) AS n
        FROM t
        GROUP BY id
        """
        )
    }

    @Test("CREATE TABLE AS SELECT has no column list")
    func createTableAsSelect() throws {
        try expectFormat(
            "create table t2 as select now() as ts",
            equals: """
        CREATE TABLE t2 AS
        SELECT now() AS ts
        """
        )
    }

    @Test("As written keeps the spelling of every word of a multi-word keyword")
    func preserveKeepsEveryWord() throws {
        try expectFormat(
            "select a from t Left Outer Join u on t.id = u.id order By a union All select b from s; Insert Into t values (1)",
            options: options { $0.keywordCase = .preserve },
            equals: """
        select a
        from t
        Left Outer Join u
          on t.id = u.id
        order By a

        union All

        select b
        from s;
        Insert Into t
        values (1)
        """
        )
    }

    @Test("ClickHouse columns named like keywords keep their case")
    func clickHouseKeywordColumns() throws {
        try expectFormat(
            "SELECT database, table, name, type, default_kind FROM system.columns WHERE database = 'default' AND table = 'hits'",
            dialect: .clickhouse,
            equals: """
        SELECT database,
               table,
               name,
               type,
               default_kind
        FROM system.columns
        WHERE database = 'default'
          AND table = 'hits'
        """
        )
    }

    @Test("A keyword standing where a name stands keeps its spelling")
    func keywordNamedColumns() throws {
        try expectFormat(
            "select key, value, first, last from kv order by key desc",
            dialect: .clickhouse,
            equals: """
        SELECT key,
               value,
               first,
               last
        FROM kv
        ORDER BY key DESC
        """
        )
    }

    @Test("A ClickHouse column list keeps keyword-named columns and type names")
    func clickHouseColumnList() throws {
        try expectFormat(
            "CREATE TABLE kv (key String, value String) ENGINE = MergeTree ORDER BY key",
            dialect: .clickhouse,
            options: options { $0.dataTypeCase = .upper },
            equals: """
        CREATE TABLE kv (
          key String,
          value String
        ) ENGINE = MergeTree
        ORDER BY key
        """
        )
    }

    @Test("A nested CASE lines up under the line it starts on")
    func nestedCase() throws {
        try expectFormat(
            "select case when a = 1 then case when b = 2 then 'x' else 'y' end else 'w' end as v from t",
            equals: """
        SELECT CASE
                 WHEN a = 1 THEN CASE
                   WHEN b = 2 THEN 'x'
                   ELSE 'y'
                 END
                 ELSE 'w'
               END AS v
        FROM t
        """
        )
    }

    @Test("A subquery in a SELECT item sits under its column")
    func subqueryInSelectItem() throws {
        try expectFormat(
            "select id, (select max(o.total) from orders o where o.user_id = u.id) as top_order, name from users u",
            equals: """
        SELECT id,
               (
                 SELECT max(o.total)
                 FROM orders o
                 WHERE o.user_id = u.id
               ) AS top_order,
               name
        FROM users u
        """
        )
    }

    @Test("A subquery on an AND line sits under that line")
    func subqueryOnAndLine() throws {
        try expectFormat(
            "select * from t where a = 1 and exists (select 1 from u where u.id = t.id)",
            equals: """
        SELECT *
        FROM t
        WHERE a = 1
          AND EXISTS (
            SELECT 1
            FROM u
            WHERE u.id = t.id
          )
        """
        )
    }

    @Test("A CASE in a SET item lines up with its item")
    func caseInSetItem() throws {
        try expectFormat(
            "update t set a = 1, b = case when c then 2 else 3 end where id = 1",
            equals: """
        UPDATE t
        SET a = 1,
            b = CASE
              WHEN c THEN 2
              ELSE 3
            END
        WHERE id = 1
        """
        )
    }

    @Test("HAVING breaks its conditions whether or not a WHERE came first")
    func havingIsAConditionList() throws {
        try expectFormat(
            "select a from t group by a having count(*) > 1 and sum(b) > 2",
            equals: """
        SELECT a
        FROM t
        GROUP BY a
        HAVING count(*) > 1
          AND sum(b) > 2
        """
        )
    }

    @Test("A paren after a comma keeps its space")
    func valuesRowsKeepTheirSpace() throws {
        try expectFormat(
            "insert into t (a, b) values (1, 'x'),(2, 'y'); select concat(a,(b + c)) from t where x in ((1, 2),(3, 4))",
            equals: """
        INSERT INTO t (a, b)
        VALUES (1, 'x'), (2, 'y');
        SELECT concat(a, (b + c))
        FROM t
        WHERE x IN ((1, 2), (3, 4))
        """
        )
    }

    @Test("END of a BEGIN block adds no blank line")
    func endOfBlockIsIdempotent() throws {
        try expectFormat(
            "create procedure p() begin select 1; end",
            equals: """
        CREATE procedure p() BEGIN
        SELECT 1;
        END
        """
        )
    }

    @Test("IS DISTINCT FROM stays inline")
    func isDistinctFromStaysInline() throws {
        try expectFormat(
            "select * from t where a is distinct from b",
            dialect: .postgresql,
            equals: """
        SELECT *
        FROM t
        WHERE a IS DISTINCT FROM b
        """
        )
    }

    @Test("A line comment in a CRLF document ends at its line")
    func crlfLineComment() throws {
        let sql = """
        select a from t -- note
        where x = 1 and y = 2
        """
        try expectFormat(
            sql.replacingOccurrences(of: "\n", with: "\r\n"),
            equals: """
        SELECT a
        FROM t
        -- note
        WHERE x = 1
          AND y = 2
        """
        )
    }

    @Test("Clause items below the keyword")
    func clauseItemsBelow() throws {
        try expectFormat(
            "select u.id as user_id, u.name as user_name, count(o.id) as order_count from users u left join orders o on u.id = o.user_id where u.status = 'active' and o.created_at >= '2026-01-01' group by u.id, u.name",
            options: options { $0.clauseItems = .newLine },
            equals: """
        SELECT
          u.id AS user_id,
          u.name AS user_name,
          count(o.id) AS order_count
        FROM users u
        LEFT JOIN orders o
          ON u.id = o.user_id
        WHERE
          u.status = 'active'
          AND o.created_at >= '2026-01-01'
        GROUP BY u.id, u.name
        """
        )
    }

    @Test("A WITH list below the keyword")
    func clauseItemsBelowWith() throws {
        try expectFormat(
            "with a as (select 1 as x), b as (select x from a) select x from b",
            options: options { $0.clauseItems = .newLine },
            equals: """
        WITH
          a AS (
            SELECT 1 AS x
          ),
          b AS (
            SELECT x
            FROM a
          )
        SELECT x
        FROM b
        """
        )
    }

    @Test("A single item stays beside its keyword")
    func clauseItemsBelowSingle() throws {
        try expectFormat(
            "select * from t where a = 1",
            options: options { $0.clauseItems = .newLine },
            equals: """
        SELECT *
        FROM t
        WHERE a = 1
        """
        )
    }

    @Test("A SET list below the keyword with leading commas")
    func clauseItemsBelowSet() throws {
        try expectFormat(
            "update users set name = 'a', email = 'b' where id = 1",
            options: options {
                $0.clauseItems = .newLine
                $0.commaPosition = .leading
            },
            equals: """
        UPDATE users
        SET
          name = 'a'
          , email = 'b'
        WHERE id = 1
        """
        )
    }

    @Test("AND at the end of the line")
    func logicalOperatorAfter() throws {
        try expectFormat(
            "select * from u where u.status = 'active' and o.created_at >= '2026-01-01'",
            options: options { $0.logicalOperatorNewline = .after },
            equals: """
        SELECT *
        FROM u
        WHERE u.status = 'active' AND
              o.created_at >= '2026-01-01'
        """
        )
    }

    @Test("AND at the end of the line with items below")
    func logicalOperatorAfterBelow() throws {
        try expectFormat(
            "select * from t where a = 1 and b = 2",
            options: options {
                $0.clauseItems = .newLine
                $0.logicalOperatorNewline = .after
            },
            equals: """
        SELECT *
        FROM t
        WHERE
          a = 1 AND
          b = 2
        """
        )
    }

    @Test("AND at the end of a HAVING line")
    func logicalOperatorAfterHaving() throws {
        try expectFormat(
            "select a from t group by a having count(*) > 1 or sum(b) > 2",
            options: options { $0.logicalOperatorNewline = .after },
            equals: """
        SELECT a
        FROM t
        GROUP BY a
        HAVING count(*) > 1 OR
               sum(b) > 2
        """
        )
    }

    @Test("Data type case rewrites types and leaves names spelled like types")
    func dataTypeCaseUpper() throws {
        try expectFormat(
            "create table t (id int primary key, date date, name varchar(255)); select date from t where date > now()",
            dialect: .postgresql,
            options: options { $0.dataTypeCase = .upper },
            equals: """
        CREATE TABLE t (
          id INT PRIMARY KEY,
          date DATE,
          name VARCHAR(255)
        );
        SELECT date
        FROM t
        WHERE date > now()
        """
        )
    }

    @Test("Data type case lower")
    func dataTypeCaseLower() throws {
        try expectFormat(
            "SELECT CAST(x AS DECIMAL(10, 2)) AS d, CAST(y AS DATE) FROM t",
            options: options { $0.dataTypeCase = .lower },
            equals: """
        SELECT CAST(x AS decimal(10, 2)) AS d,
               CAST(y AS date)
        FROM t
        """
        )
    }

    @Test("Data type case leaves types alone where the engine matches them by exact case")
    func dataTypeCaseCaseSensitiveEngine() throws {
        try expectFormat(
            "SELECT CAST(x AS String), toString(y) FROM t",
            dialect: .clickhouse,
            options: options { $0.dataTypeCase = .upper },
            equals: """
        SELECT CAST(x AS String),
               toString(y)
        FROM t
        """
        )
    }

    @Test("Data type case leaves a column spelled like a type alone")
    func dataTypeCaseLeavesColumnsSpelledLikeTypes() throws {
        try expectFormat(
            "SELECT date + 1, date - interval '1 day', x::date, date FROM t "
                + "WHERE date = '2020-01-01' ORDER BY date",
            dialect: .postgresql,
            options: options {
                $0.dataTypeCase = .upper
                $0.keywordCase = .preserve
            },
            equals: """
        SELECT date + 1,
               date - interval '1 day',
               x :: DATE,
               date
        FROM t
        WHERE date = '2020-01-01'
        ORDER BY date
        """
        )
        try expectFormat(
            "select date, text from t group by date having max(date) > 1",
            options: options { $0.dataTypeCase = .upper },
            equals: """
        SELECT date,
               text
        FROM t
        GROUP BY date
        HAVING max(date) > 1
        """
        )
    }

    @Test("Data type case rewrites routine parameters, RETURNS and ALTER TABLE column types")
    func dataTypeCaseInDeclarations() throws {
        try expectFormat(
            "CREATE FUNCTION f(date date, b integer, OUT c text) RETURNS SETOF integer AS $$ select 1 $$ LANGUAGE sql; "
                + "DROP FUNCTION f(integer, text)",
            dialect: .postgresql,
            options: options {
                $0.dataTypeCase = .upper
                $0.keywordCase = .preserve
            },
            equals: """
        CREATE FUNCTION f(date DATE, b INTEGER, OUT c TEXT) RETURNS SETOF INTEGER AS $$ select 1 $$ LANGUAGE sql;
        DROP FUNCTION f(integer, text)
        """
        )
        try expectFormat(
            "alter table t modify column d datetime, add e int, add date date",
            options: options { $0.dataTypeCase = .upper },
            equals: "ALTER TABLE t MODIFY COLUMN d DATETIME, ADD e INT, ADD date DATE"
        )
    }

    @Test("A column named go left alone by a leading comma stays off a line of its own")
    func noManufacturedBatchSeparator() throws {
        try expectFormat(
            "select go, x from t",
            dialect: .mssql,
            options: options {
                $0.clauseItems = .newLine
                $0.commaPosition = .leading
            },
            equals: """
        SELECT go
          , x
        FROM t
        """
        )
    }

    @Test("A statement starting with a column named delimiter stays off a line of its own")
    func noManufacturedDelimiterDirective() throws {
        try expectFormat(
            "select delimiter as d, x from t; delimiter as e",
            options: options { $0.clauseItems = .newLine },
            equals: """
        SELECT
          delimiter AS d,
          x
        FROM t; delimiter AS e
        """
        )
    }

    @Test("A division operator stays off a line of its own under SQL*Plus rules")
    func noManufacturedSlashLine() throws {
        try expectFormat(
            "select a\n/* x */ / -- y\n2 from dual",
            dialect: .oracle,
            equals: """
        SELECT a
        /* x */ /
        -- y
        2
        FROM dual
        """
        )
    }

    // The quadratic count took 24 s optimized and minutes in a debug build; linear takes under 2 s in a debug build, so
    // the bound leaves room for a slow CI runner.
    @Test("A script of 20,000 GO batches formats in linear time")
    func manyBatchesFormatInLinearTime() throws {
        let script = (0..<20_000).map { "SELECT \($0)\nGO\n" }.joined()
        var formatted = ""
        let elapsed = try ContinuousClock().measure {
            formatted = try formatter.format(script, dialect: .mssql).formattedSQL
        }
        #expect(formatted.components(separatedBy: "\n").filter { $0 == "GO" }.count == 20_000)
        #expect(elapsed < .seconds(30))
    }

    @Test(
        "Formatting keeps every statement and batch boundary under every layout",
        arguments: [
            (DatabaseType.mssql, "select go, x from t"),
            (DatabaseType.mssql, "select x, go from t where go = 1 and y = 2"),
            (DatabaseType.mssql, "select a, -- c\ngo from t"),
            (DatabaseType.mssql, "select go, x from t\nGO\nselect y, go from u"),
            (DatabaseType.mssql, "select * from t where go and x = 1"),
            (DatabaseType.mysql, "select delimiter as d, x from t; delimiter as e"),
            (DatabaseType.mysql, "select x from t; delimiter, y from u"),
            (DatabaseType.oracle, "select a\n/* x */ / -- y\n2 from dual"),
            (DatabaseType.oracle, "select a / b, c from t where d / 2 > 1"),
        ]
    )
    func keepsStatementBoundaries(dialect: DatabaseType, sql: String) throws {
        let grammar = dialect.lexicalGrammar
        func directives(_ text: String) -> Int {
            SQLTokenizer().tokenize(text, grammar: grammar).filter { $0.type == .directive }.count
        }
        for clauseItems in SQLFormatterClauseItems.allCases {
            for commaPosition in SQLFormatterCommaPosition.allCases {
                for logicalOperatorNewline in SQLFormatterLogicalOperatorNewline.allCases {
                    let layout = options {
                        $0.clauseItems = clauseItems
                        $0.commaPosition = commaPosition
                        $0.logicalOperatorNewline = logicalOperatorNewline
                    }
                    let formatted = try formatter.format(sql, dialect: dialect, options: layout).formattedSQL
                    #expect(
                        SQLStatementScanner.executableStatements(in: formatted, grammar: grammar).count
                            == SQLStatementScanner.executableStatements(in: sql, grammar: grammar).count
                    )
                    #expect(
                        SQLStatementScanner.batchSeparators(in: formatted, grammar: grammar).count
                            == SQLStatementScanner.batchSeparators(in: sql, grammar: grammar).count
                    )
                    #expect(directives(formatted) == directives(sql))
                    #expect(try formatter.format(formatted, dialect: dialect, options: layout).formattedSQL == formatted)
                }
            }
        }
    }

    // MARK: - Idempotency Under Options

    @Test(
        "Formatting twice gives the same result under every option",
        arguments: [
            SQLFormatterOptions(indentStyle: .tabs, commaPosition: .leading, alignAliases: true),
            SQLFormatterOptions(indentWidth: 4, keywordCase: .lower, functionCase: .upper, lineWidth: 60),
            SQLFormatterOptions(lineWidth: 120, joinCondition: .sameLine, alignAliases: true),
            SQLFormatterOptions(clauseItems: .newLine, logicalOperatorNewline: .after),
            SQLFormatterOptions(commaPosition: .leading, alignAliases: true, clauseItems: .newLine, dataTypeCase: .upper),
            SQLFormatterOptions(keywordCase: .preserve, lineWidth: 40, logicalOperatorNewline: .after, dataTypeCase: .lower),
        ]
    )
    func idempotentUnderOptions(_ options: SQLFormatterOptions) throws {
        let sql = "select u.id as user_id, count(o.id) as n, row_number() over (order by u.id) as rn, "
            + "cast(o.total as decimal(10, 2)) as total from users u left join orders o on u.id = o.user_id "
            + "where u.status = 'active' and o.total > 10 and exists (select 1 from r where r.id = u.id) "
            + "group by u.id having count(*) > 1 and sum(o.total) > 2 order by n desc"
        let first = try format(sql, options: options)
        #expect(try format(first, options: options) == first)
    }
}
