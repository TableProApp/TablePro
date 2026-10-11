//
//  QueryTableReferenceResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSQLGrammar
import Testing

struct QueryTableReferenceResolverTests {
    private func names(_ sql: String, grammar: SQLLexicalGrammar = .ansi) -> [String] {
        QueryTableReferenceResolver.sqlReferences(in: sql, grammar: grammar).map(\.displayName)
    }

    @Test("FROM, JOIN and a comma list resolve in query order")
    func fromJoinAndList() {
        let sql = "SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id, regions r WHERE r.id = 1"
        #expect(names(sql) == ["orders", "customers", "regions"])
    }

    @Test("A schema-qualified and quoted name keeps its qualifier and its spaces")
    func qualifiedAndQuoted() {
        let sql = #"SELECT * FROM sales."Order Details" od JOIN public.products p ON p.id = od.product_id"#
        let references = QueryTableReferenceResolver.sqlReferences(in: sql, grammar: .ansi)
        #expect(references == [
            QueryTableReference(name: "Order Details", qualifiers: ["sales"]),
            QueryTableReference(name: "products", qualifiers: ["public"])
        ])
    }

    @Test("Backticked and bracketed names are read as identifiers")
    func backticksAndBrackets() {
        #expect(names("SELECT * FROM `my-table`", grammar: .backtickQuotes) == ["my-table"])
        #expect(names("SELECT * FROM [dbo].[Order Items]", grammar: .bracketQuotedIdentifiers) == ["dbo.Order Items"])
    }

    @Test("A table named only inside a string literal or a comment is not a reference")
    func literalsAndCommentsIgnored() {
        let sql = """
        -- FROM audit_log
        SELECT 'FROM secrets' AS note /* JOIN hidden */ FROM orders
        """
        #expect(names(sql) == ["orders"])
    }

    @Test("A column or keyword that shares a table's name is not a reference")
    func columnsAreNotTables() {
        let sql = "SELECT status, \"order\" FROM invoices WHERE status = 'open' ORDER BY created_at"
        #expect(names(sql) == ["invoices"])
    }

    @Test("CTE names are dropped and the tables inside them are kept")
    func commonTableExpressions() {
        let sql = """
        WITH recent AS (SELECT * FROM orders WHERE created_at > now()),
             totals(customer_id, total) AS (SELECT customer_id, sum(amount) FROM payments GROUP BY 1)
        SELECT * FROM recent JOIN totals USING (customer_id)
        """
        #expect(names(sql) == ["orders", "payments"])
    }

    @Test("A subquery in FROM does not end the comma list and its own tables count")
    func subqueryInFromList() {
        let sql = "SELECT * FROM (SELECT id FROM users) u, accounts a WHERE a.user_id = u.id"
        #expect(names(sql) == ["users", "accounts"])
    }

    @Test("Write targets resolve: UPDATE, INSERT INTO, DELETE FROM, MERGE and CREATE INDEX")
    func writeTargets() {
        #expect(names("UPDATE accounts SET balance = 0 WHERE id = 1") == ["accounts"])
        #expect(names("INSERT INTO audit (a, b) SELECT a, b FROM staging") == ["audit", "staging"])
        #expect(names("DELETE FROM sessions USING users WHERE users.id = sessions.user_id") == ["sessions", "users"])
        #expect(names("MERGE INTO target t USING source s ON t.id = s.id WHEN MATCHED THEN UPDATE SET v = s.v")
            == ["target", "source"])
        #expect(names("CREATE UNIQUE INDEX CONCURRENTLY idx_email ON users (email)") == ["users"])
    }

    @Test("Clauses that look like table slots are not read as tables")
    func nonTableSlots() {
        #expect(names("INSERT INTO t (a) VALUES (1) ON DUPLICATE KEY UPDATE a = 2") == ["t"])
        #expect(names("SELECT * FROM t FOR UPDATE OF t NOWAIT") == ["t"])
        #expect(names("SELECT * FROM a JOIN b USING (id)") == ["a", "b"])
        #expect(names("SELECT * FROM generate_series(1, 10) g").isEmpty)
        #expect(names("SELECT * FROM a JOIN b ON b.id IN (1, 2) WHERE a.x IN (3, 4) ORDER BY a.x, b.y") == ["a", "b"])
    }

    @Test("FROM inside a function's arguments or IS DISTINCT FROM names a column, not a table")
    func fromInsideFunctions() {
        #expect(names("SELECT EXTRACT(YEAR FROM created_at), SUBSTRING(code FROM 2 FOR 3) FROM orders") == ["orders"])
        #expect(names("SELECT TRIM(BOTH ' ' FROM name) FROM users WHERE a IS DISTINCT FROM b") == ["users"])
        #expect(names("SELECT COALESCE((SELECT max(id) FROM audit), 0) FROM t") == ["audit", "t"])
        #expect(names("SELECT ARRAY(SELECT id FROM tags) FROM posts") == ["tags", "posts"])
    }

    @Test("ON UPDATE in a column or key definition is not an UPDATE statement")
    func onUpdateIsNotATable() {
        #expect(names("ALTER TABLE t ADD COLUMN u TIMESTAMP ON UPDATE CURRENT_TIMESTAMP") == ["t"])
        #expect(names("ALTER TABLE t ADD FOREIGN KEY (a) REFERENCES p (id) ON UPDATE CASCADE") == ["t", "p"])
    }

    @Test("A name repeated in the statement is reported once")
    func duplicatesCollapse() {
        #expect(names("SELECT * FROM t WHERE id IN (SELECT id FROM t)") == ["t"])
    }

    @Test("Scanning stops at the cap instead of reading a huge statement whole")
    func scanIsCapped() {
        let tail = String(repeating: " ", count: QueryTableReferenceResolver.scanLimit) + "JOIN late ON 1 = 1"
        #expect(names("SELECT * FROM early" + tail) == ["early"])
    }

    @Test("Non-SQL editors yield identifier tokens, quoted strings included")
    func identifierTokensForDocumentStores() {
        let tokens = QueryTableReferenceResolver.identifierTokens(in: #"db.getCollection("orders").find({status: 'paid'})"#)
        #expect(tokens.contains("orders"))
        #expect(tokens.contains("db"))
        #expect(tokens.contains("paid"))
    }
}
