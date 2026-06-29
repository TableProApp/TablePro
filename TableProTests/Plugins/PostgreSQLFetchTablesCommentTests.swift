import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries.fetchTables comments")
struct PostgreSQLFetchTablesCommentTests {
    @Test("Base query selects the table comment via obj_description")
    func baseQuerySelectsComment() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
            includeMaterializedViews: false,
            includeForeignTables: false
        )
        #expect(query.contains("table_comment"))
        #expect(query.contains("obj_description"))
    }

    @Test("Base query does not reference pg_class/pg_namespace so the portability fallback stays minimal")
    func baseQueryStaysPortable() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
            includeMaterializedViews: false,
            includeForeignTables: false
        )
        #expect(!query.contains("pg_catalog.pg_class"))
        #expect(!query.contains("pg_catalog.pg_namespace"))
    }

    @Test("Every union branch projects a comment column so columns stay aligned")
    func allBranchesProjectComment() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
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
            schemaLiteral: "public",
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
