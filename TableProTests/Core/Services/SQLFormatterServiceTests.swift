//
//  SQLFormatterServiceTests.swift
//  TableProTests
//
//  Tests for SQLFormatterService — exact output assertions for every SQL construct.
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQL Formatter Service")
@MainActor
struct SQLFormatterServiceTests {
    let formatter = SQLFormatterService()

    private func format(_ sql: String, options: SQLFormatterOptions = .default) throws -> String {
        try formatter.format(sql, dialect: .mysql).formattedSQL
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
        WHERE active = true
        """)
    }

    @Test("WHERE with AND/OR — each condition on new line")
    func whereWithAndOr() throws {
        let result = try format("select * from users where active = true and role = 'admin' or age > 18")
        #expect(result == """
        SELECT *
        FROM users
        WHERE active = true
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
        ORDER BY name asc
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
          WHERE active = true
        ) as active_users
        """)
    }

    @Test("Subquery in WHERE")
    func subqueryInWhere() throws {
        let result = try format("select * from users where id in (select user_id from orders)")
        #expect(result == """
        SELECT *
        FROM users
        WHERE id in (
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
               END as label
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
          WHERE active = true
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
        WHERE active = false
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

    @Test("Multiple statements separated by semicolons")
    func multipleStatements() throws {
        let result = try format("select 1; select 2;")
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
        options.uppercaseKeywords = false
        let result = try formatter.format("select * from users", dialect: .mysql, options: options).formattedSQL
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
        let large = String(repeating: "select 1; ", count: 600_000)
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
}
