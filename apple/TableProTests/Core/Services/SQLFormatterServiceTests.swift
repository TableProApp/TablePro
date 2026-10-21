//
//  SQLFormatterServiceTests.swift
//  TableProTests
//
//  Tests for SQLFormatterService — exact output assertions for every SQL construct.
//

import Foundation
import TableProPluginKit
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

    @Test("Window frame ROWS BETWEEN stays inline")
    func windowFrameInline() throws {
        let result = try format("select sum(x) over (order by id rows between unbounded preceding and current row) as running from t")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0].contains("ROWS BETWEEN"))
        #expect(lines[1] == "FROM t")
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

    // MARK: - Idempotency Under Options

    @Test(
        "Formatting twice gives the same result under every option",
        arguments: [
            SQLFormatterOptions(indentStyle: .tabs, commaPosition: .leading, alignAliases: true),
            SQLFormatterOptions(indentWidth: 4, keywordCase: .lower, functionCase: .upper, lineWidth: 60),
            SQLFormatterOptions(lineWidth: 120, joinCondition: .sameLine, alignAliases: true),
        ]
    )
    func idempotentUnderOptions(_ options: SQLFormatterOptions) throws {
        let sql = "select u.id as user_id, count(o.id) as n from users u left join orders o on u.id = o.user_id "
            + "where u.status = 'active' and o.total > 10 group by u.id order by n desc"
        let first = try format(sql, options: options)
        #expect(try format(first, options: options) == first)
    }
}
