import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLFetchTablesCommentTests {
    private static let attempts = PostgreSQLTableListingLadder.degradableAttempts
        + [PostgreSQLTableListingLadder.leastCapableAttempt]

    @Test("The comment comes from a join on pg_description, keyed to the relation itself")
    func commentComesFromTheDescriptionJoin() {
        let query = PostgreSQLTableListing.query(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true
        )
        #expect(query.contains("d.description AS table_comment"))
        #expect(query.contains("LEFT JOIN pg_catalog.pg_description d"))
        #expect(query.contains(
            "ON d.objoid = c.oid AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass AND d.objsubid = 0"
        ))
        #expect(!query.contains("obj_description"))
    }

    @Test("No rung reads to_regclass, whose text form exists only from PostgreSQL 9.6")
    func noRungUsesToRegclass() {
        for attempt in Self.attempts {
            let query = PostgreSQLTableListingLadder.query(
                for: attempt, in: .schema("public"), includeMaterializedViews: true, includeForeignTables: true
            )
            #expect(!query.contains("to_regclass"), "\(attempt.label)")
        }
    }

    @Test("Comments without partition awareness still join pg_description")
    func commentsWithoutPartitionsKeepTheJoin() {
        let query = PostgreSQLTableListing.query(
            schema: "public",
            includeMaterializedViews: false,
            includeForeignTables: false,
            includeComments: true,
            includePartitionAwareness: false
        )
        #expect(query.contains("LEFT JOIN pg_catalog.pg_description d"))
        #expect(!query.contains("pg_catalog.pg_inherits"))
    }

    @Test("The comment-free rung projects a NULL comment and joins nothing for it")
    func commentFreeRungSkipsTheJoin() {
        let query = PostgreSQLTableListing.query(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true,
            includeComments: false
        )
        #expect(query.contains("NULL::text AS table_comment"))
        #expect(!query.contains("pg_description"))
        #expect(!query.contains("regclass"))
    }

    @Test("The information_schema rung reads no catalog table at all")
    func informationSchemaRungStaysPortable() {
        let query = PostgreSQLTableListing.informationSchemaQuery(in: .schema("public"))
        #expect(query.contains("FROM information_schema.tables t"))
        #expect(query.contains("NULL::text AS table_comment"))
        #expect(!query.contains("pg_catalog."))
    }
}
