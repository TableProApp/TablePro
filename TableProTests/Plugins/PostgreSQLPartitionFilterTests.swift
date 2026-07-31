import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries partition awareness")
struct PostgreSQLPartitionFilterTests {
    private func awareQuery() -> String {
        PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
            includeMaterializedViews: false,
            includeForeignTables: false
        )
    }

    @Test("Partition children are excluded through pg_inherits")
    func excludesPartitionChildren() {
        let query = awareQuery()
        #expect(query.contains("NOT EXISTS"))
        #expect(query.contains("pg_catalog.pg_inherits"))
        #expect(query.contains("i.inhrelid = pc.oid"))
    }

    @Test("Children are matched by their parent relkind, not relispartition")
    func usesParentRelkindNotRelispartition() {
        let query = awareQuery()
        #expect(query.contains("parent.relkind IN ('p', 'I')"))
        #expect(!query.contains("relispartition"))
    }

    @Test("A partitioned parent is labelled instead of reported as a plain base table")
    func labelsPartitionedParent() {
        let query = awareQuery()
        #expect(query.contains("CASE WHEN pc.relkind = 'p' THEN 'PARTITIONED TABLE' ELSE t.table_type END"))
    }

    @Test("Rows still come from information_schema so privilege filtering is preserved")
    func keepsInformationSchemaAsRowSource() {
        let query = awareQuery()
        #expect(query.contains("FROM information_schema.tables t"))
    }

    @Test("Partition awareness degrades independently of the optional catalogs")
    func partitionAwarenessDegradesIndependently() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
            includeMaterializedViews: true,
            includeForeignTables: true,
            includePartitionAwareness: false
        )
        #expect(!query.contains("pg_catalog.pg_inherits"))
        #expect(!query.contains("PARTITIONED TABLE"))
        #expect(query.contains("pg_matviews"))
        #expect(query.contains("pg_foreign_table"))
    }

    @Test("Every union branch still projects three aligned columns when partition aware")
    func unionBranchesStayAligned() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
            includeMaterializedViews: true,
            includeForeignTables: true
        )
        let typeColumns = query.components(separatedBy: "AS table_type").count - 1
        let commentColumns = query.components(separatedBy: "AS table_comment").count - 1
        let branches = query.components(separatedBy: "UNION ALL").count
        #expect(typeColumns == branches)
        #expect(commentColumns == branches)
    }

    @Test("Partition listing is scoped to one parent in one schema")
    func fetchPartitionsScopesToParent() {
        let query = PostgreSQLSchemaQueries.fetchPartitions(schemaLiteral: "public", tableLiteral: "orders")
        #expect(query.contains("pn.nspname = 'public'"))
        #expect(query.contains("parent.relname = 'orders'"))
        #expect(query.contains("parent.relkind = 'p'"))
    }

    @Test("Partition listing sorts the DEFAULT partition last")
    func fetchPartitionsSortsDefaultLast() {
        let query = PostgreSQLSchemaQueries.fetchPartitions(schemaLiteral: "public", tableLiteral: "orders")
        #expect(query.contains("ORDER BY pg_catalog.pg_get_expr(cc.relpartbound, cc.oid) = 'DEFAULT', cc.relname"))
    }

    @Test("Partition listing projects relkind so subpartitioned children stay expandable")
    func fetchPartitionsProjectsRelkind() {
        let query = PostgreSQLSchemaQueries.fetchPartitions(schemaLiteral: "public", tableLiteral: "orders")
        #expect(query.contains("SELECT cc.relname, cc.relkind"))
    }
}

@Suite("PostgreSQL table listing degradation ladder")
struct PostgreSQLTableListingLadderTests {
    @Test("Partition awareness survives every rung that only drops columns")
    func partitionAwarenessDegradesLast() {
        let attempts = PostgreSQLTableListingLadder.degradableAttempts
        let everyRungKeepsPartitions = attempts.filter(\.includePartitionAwareness).count == attempts.count
        #expect(everyRungKeepsPartitions)
        #expect(attempts.first?.includeOptionalCatalogs == true)
        #expect(attempts.first?.includeComments == true)
    }

    @Test("Each rung drops strictly more than the one before it")
    func ladderDegradesMonotonically() {
        let attempts = PostgreSQLTableListingLadder.degradableAttempts
            + [PostgreSQLTableListingLadder.leastCapableAttempt]
        let ranks = attempts.map { attempt in
            [attempt.includeOptionalCatalogs, attempt.includeComments, attempt.includePartitionAwareness]
                .filter { $0 }.count
        }
        let descending = ranks.sorted { $0 > $1 }
        #expect(ranks == descending)
        #expect(Set(ranks).count == ranks.count)
    }

    @Test("Only the final rung abandons partition awareness")
    func finalRungAbandonsPartitionAwareness() {
        let last = PostgreSQLTableListingLadder.leastCapableAttempt
        #expect(!last.includePartitionAwareness)
        #expect(!last.includeOptionalCatalogs)
        #expect(!last.includeComments)
    }

    @Test("Only a missing relation or function degrades the listing")
    func onlyCatalogFailuresDegrade() {
        #expect(PostgreSQLTableListingLadder.isDegradable(sqlState: "42P01"))
        #expect(PostgreSQLTableListingLadder.isDegradable(sqlState: "42883"))
        #expect(!PostgreSQLTableListingLadder.isDegradable(sqlState: "42703"))
        #expect(!PostgreSQLTableListingLadder.isDegradable(sqlState: "28000"))
        #expect(!PostgreSQLTableListingLadder.isDegradable(sqlState: nil))
    }
}
