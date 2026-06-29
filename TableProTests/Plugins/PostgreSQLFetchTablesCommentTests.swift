import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries.fetchTables comments")
struct PostgreSQLFetchTablesCommentTests {
    @Test("Base query selects the table comment from pg_description")
    func baseQuerySelectsComment() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
            includeMaterializedViews: false,
            includeForeignTables: false
        )
        #expect(query.contains("table_comment"))
        #expect(query.contains("pg_description"))
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
}
