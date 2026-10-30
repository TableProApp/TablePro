//
//  QueryClassifierEmbeddedStatementTests.swift
//  TableProTests
//
//  SurrealQL takes a statement wherever it takes a value and CockroachDB takes one in brackets as a table, so a gate
//  that read only the first word would see a SELECT whatever the SELECT runs. These hold the tier to what it holds.
//

import Foundation
@testable import TablePro
import Testing

struct QueryClassifierEmbeddedStatementTests {
    @Test("A SurrealQL SELECT that holds a writing statement is a write", arguments: [
        "SELECT * FROM (DELETE orders RETURN BEFORE)",
        "SELECT * FROM orders WHERE (DELETE orders)",
        "SELECT * FROM (REMOVE TABLE orders)",
        "SELECT * FROM (DEFINE USER x ON DB PASSWORD 'p' ROLES OWNER)",
        "SELECT * FROM (UPDATE orders SET total = 0)",
        "SELECT * FROM { CREATE orders }",
        "SELECT * FROM DELETE orders",
        "SELECT (IF true THEN (RELATE a:1->likes->b:1) END) FROM 1",
        "select * from (/* all */ delete orders)",
    ])
    func surrealQLSubqueryWrites(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .surrealdb) == .write)
        #expect(QueryClassifier.isWriteQuery(sql, databaseType: .surrealdb))
        #expect(!QueryClassifier.isMultiStatement(sql, databaseType: .surrealdb))
    }

    @Test("A SurrealQL SELECT that only reads stays a read", arguments: [
        "SELECT * FROM orders",
        "SELECT * FROM orders WHERE id IN (SELECT VALUE id FROM paid)",
        "SELECT created, 'DELETE', \"(DELETE orders)\" FROM orders",
        "SELECT array::insert(tags, 'x'), string::replace(a, 'b', 'c'), time::now() FROM orders",
        "SELECT row.update, $delete, `create`, my_function(1) FROM orders -- (DELETE orders)",
        "INFO FOR DB",
    ])
    func surrealQLReads(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .surrealdb) == .safe)
        #expect(!QueryClassifier.isDangerousQuery(sql, databaseType: .surrealdb))
    }

    @Test("A SurrealQL DELETE inside another statement is held to a WHERE of its own")
    func surrealQLEmbeddedDeleteWithoutWhere() {
        for sql in [
            "SELECT * FROM orders WHERE (DELETE orders)",
            "SELECT DELETE orders FROM customers WHERE true",
            "UPDATE a SET gone = (DELETE orders) WHERE id = 1",
        ] {
            #expect(QueryClassifier.isDangerousQuery(sql, databaseType: .surrealdb), "\(sql)")
        }
        for sql in [
            "SELECT * FROM (DELETE orders WHERE id = 1)",
            "DEFINE TABLE post PERMISSIONS FOR select, create FULL FOR update, delete NONE",
            "DEFINE FIELD author ON post TYPE record<user> REFERENCE ON DELETE CASCADE",
        ] {
            #expect(!QueryClassifier.isDangerousQuery(sql, databaseType: .surrealdb), "\(sql)")
        }
    }

    @Test("A CockroachDB SELECT from a bracketed statement that writes is a write", arguments: [
        "SELECT * FROM [DELETE FROM orders RETURNING id]",
        "SELECT * FROM [ UPDATE orders SET total = 0 RETURNING id ]",
        "SELECT * FROM [UPSERT INTO orders VALUES (1) RETURNING id]",
        "SELECT * FROM [EXPLAIN ANALYZE DELETE FROM orders]",
        "SELECT * FROM [WITH gone AS (DELETE FROM orders RETURNING id) SELECT * FROM gone]",
        "SELECT * FROM [SELECT * FROM [DELETE FROM orders RETURNING id]]",
        "SELECT * FROM [/* all */ DELETE FROM orders RETURNING id]",
    ])
    func cockroachStatementSourceWrites(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .cockroachdb) == .write)
        #expect(!QueryClassifier.isMultiStatement(sql, databaseType: .cockroachdb))
    }

    @Test("A CockroachDB SELECT from a bracketed statement that reads stays a read", arguments: [
        "SELECT * FROM [SHOW TABLES]",
        "SELECT * FROM [EXPLAIN DELETE FROM orders]",
        "SELECT a[1], ARRAY[1, 2] FROM t FOR UPDATE",
        "SELECT '[DELETE FROM t]' FROM t",
    ])
    func cockroachStatementSourceReads(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .cockroachdb) == .safe)
    }

    @Test("A CockroachDB DELETE in brackets is held to a WHERE of its own")
    func cockroachBracketedDeleteWithoutWhere() {
        #expect(
            QueryClassifier.isDangerousQuery(
                "SELECT * FROM [DELETE FROM orders RETURNING id] WHERE id = 1", databaseType: .cockroachdb
            )
        )
        #expect(
            !QueryClassifier.isDangerousQuery(
                "SELECT * FROM [DELETE FROM orders WHERE id = 1 RETURNING id]", databaseType: .cockroachdb
            )
        )
    }
}
