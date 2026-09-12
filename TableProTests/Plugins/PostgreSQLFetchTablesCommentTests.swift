import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries.fetchTables comments")
struct PostgreSQLFetchTablesCommentTests {
    @Test("Base query selects the table comment via obj_description")
    func baseQuerySelectsComment() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schema: "public",
            includeMaterializedViews: false,
            includeForeignTables: false
        )
        #expect(query.contains("table_comment"))
        #expect(query.contains("obj_description(pc.oid, 'pg_class')"))
    }

    @Test("No rung reads to_regclass, whose text form exists only from PostgreSQL 9.6")
    func noRungUsesToRegclass() {
        let attempts = PostgreSQLTableListingLadder.degradableAttempts + [PostgreSQLTableListingLadder.leastCapableAttempt]
        for attempt in attempts {
            let query = PostgreSQLSchemaQueries.fetchTables(
                schema: "public",
                includeMaterializedViews: attempt.includeOptionalCatalogs,
                includeForeignTables: attempt.includeOptionalCatalogs,
                includeComments: attempt.includeComments,
                includePartitionAwareness: attempt.includePartitionAwareness
            )
            #expect(!query.contains("to_regclass"), "\(attempt.label)")
        }
    }

    @Test("Comments without partition awareness still join pg_class for the relation oid")
    func commentsWithoutPartitionsKeepTheClassJoin() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schema: "public",
            includeMaterializedViews: false,
            includeForeignTables: false,
            includeComments: true,
            includePartitionAwareness: false
        )
        #expect(query.contains("LEFT JOIN pg_catalog.pg_class pc"))
        #expect(!query.contains("pg_catalog.pg_inherits"))
    }

    @Test("A materialized view's comment comes from its own relation oid")
    func matviewCommentUsesItsOid() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: false
        )
        #expect(query.contains("obj_description(mc.oid, 'pg_class')"))
        #expect(query.contains("JOIN pg_catalog.pg_class mc ON mc.relnamespace = mn.oid AND mc.relname = m.matviewname"))
    }

    @Test("Fully degraded query does not reference pg_class/pg_namespace so the portability fallback stays minimal")
    func fallbackQueryStaysPortable() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schema: "public",
            includeMaterializedViews: false,
            includeForeignTables: false,
            includeComments: false,
            includePartitionAwareness: false
        )
        #expect(!query.contains("pg_catalog.pg_class"))
        #expect(!query.contains("pg_catalog.pg_namespace"))
        #expect(!query.contains("pg_catalog.pg_inherits"))
    }

    @Test("Every union branch projects a comment column so columns stay aligned")
    func allBranchesProjectComment() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true
        )
        let commentColumns = query.components(separatedBy: "AS table_comment").count - 1
        let branches = query.components(separatedBy: "UNION ALL").count
        #expect(commentColumns == branches)
    }

    @Test("Comment-free fallback omits obj_description but keeps the aligned comment column")
    func commentFreeFallbackOmitsObjDescription() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true,
            includeComments: false
        )
        #expect(!query.contains("obj_description"))
        #expect(!query.contains("to_regclass"))
        let commentColumns = query.components(separatedBy: "AS table_comment").count - 1
        let branches = query.components(separatedBy: "UNION ALL").count
        #expect(commentColumns == branches)
    }
}
