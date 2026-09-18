//
//  CockroachRelationSQLTests.swift
//  TableProTests
//
//  Tests for the CockroachDB SHOW statement builders (compiled via the plugin source list).
//  Regression cover for metadata reads that took a schema argument and queried the session's
//  current schema instead, so an export or compare of an object outside the connection's own
//  schema read a same-named object in that schema or failed to find one at all.
//

import Foundation
import Testing

@Suite("CockroachRelationSQL")
struct CockroachRelationSQLTests {
    @Test("SHOW CREATE TABLE names the requested schema")
    func showCreateTableNamesRequestedSchema() {
        let statement = CockroachRelationSQL.showCreateTable(table: "orders", schema: "analytics")
        #expect(statement == "SHOW CREATE TABLE \"analytics\".\"orders\"")
    }

    @Test("SHOW CREATE VIEW names the requested schema")
    func showCreateViewNamesRequestedSchema() {
        let statement = CockroachRelationSQL.showCreateView(view: "daily_rides", schema: "analytics")
        #expect(statement == "SHOW CREATE VIEW \"analytics\".\"daily_rides\"")
    }

    @Test("SHOW INDEXES names the requested schema")
    func showIndexesNamesRequestedSchema() {
        let statement = CockroachRelationSQL.showIndexes(table: "orders", schema: "analytics")
        #expect(statement == "SHOW INDEXES FROM \"analytics\".\"orders\"")
    }

    @Test("no builder substitutes the public schema", arguments: ["public", "analytics", "s2", "Mixed Case"])
    func everyBuilderCarriesTheSchemaThrough(schema: String) {
        let statements = [
            CockroachRelationSQL.showCreateTable(table: "orders", schema: schema),
            CockroachRelationSQL.showCreateView(view: "orders", schema: schema),
            CockroachRelationSQL.showIndexes(table: "orders", schema: schema),
        ]
        for statement in statements {
            #expect(statement.contains("\"\(schema)\".\"orders\""))
            if schema != "public" {
                #expect(!statement.contains("\"public\"."))
            }
        }
    }

    @Test("an embedded double quote is doubled in both parts")
    func embeddedQuoteIsDoubled() {
        let statement = CockroachRelationSQL.showCreateTable(table: "we\"ird", schema: "my\"schema")
        #expect(statement == "SHOW CREATE TABLE \"my\"\"schema\".\"we\"\"ird\"")
    }

    @Test("the target is the shared qualified name")
    func targetIsSharedQualifiedName() {
        let target = PostgreSQLObjectQueries.qualifiedName(schema: "s", name: "t")
        #expect(CockroachRelationSQL.showCreateTable(table: "t", schema: "s").hasSuffix(target))
        #expect(CockroachRelationSQL.showCreateView(view: "t", schema: "s").hasSuffix(target))
        #expect(CockroachRelationSQL.showIndexes(table: "t", schema: "s").hasSuffix(target))
    }

    @Test("the name carries no database component")
    func nameCarriesNoDatabaseComponent() {
        let statements = [
            CockroachRelationSQL.showCreateTable(table: "orders", schema: "analytics"),
            CockroachRelationSQL.showCreateView(view: "orders", schema: "analytics"),
            CockroachRelationSQL.showIndexes(table: "orders", schema: "analytics"),
        ]
        for statement in statements {
            #expect(statement.components(separatedBy: ".").count == 2)
        }
    }
}
