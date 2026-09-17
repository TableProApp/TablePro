import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries partition awareness")
struct PostgreSQLPartitionFilterTests {
    private func awareQuery() -> String {
        PostgreSQLSchemaQueries.fetchTables(
            schema: "public",
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
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true,
            includePartitionAwareness: false
        )
        #expect(!query.contains("pg_catalog.pg_inherits"))
        #expect(!query.contains("PARTITIONED TABLE"))
        #expect(query.contains("pg_matviews"))
        #expect(query.contains("pg_foreign_table"))
    }

    @Test("Every union branch still projects four aligned columns when partition aware")
    func unionBranchesStayAligned() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true
        )
        let typeColumns = query.components(separatedBy: "AS table_type").count - 1
        let commentColumns = query.components(separatedBy: "AS table_comment").count - 1
        let countColumns = query.components(separatedBy: "AS partition_count").count - 1
        let branches = query.components(separatedBy: "UNION ALL").count
        #expect(typeColumns == branches)
        #expect(commentColumns == branches)
        #expect(countColumns == branches)
    }

    @Test("A child is dropped only when its own parent is listed too")
    func excludesOnlyChildrenOfVisibleParents() {
        let query = awareQuery()
        #expect(query.contains("FROM information_schema.tables pt"))
        #expect(query.contains("pt.table_schema = parentns.nspname"))
        #expect(query.contains("pt.table_name = parent.relname"))
    }

    @Test("The foreign-table branch excludes partitions the same way the base branch does")
    func foreignTableBranchExcludesPartitions() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schema: "public",
            includeMaterializedViews: false,
            includeForeignTables: true
        )
        #expect(query.contains("i.inhrelid = c.oid"))
        #expect(query.contains("i.inhrelid = pc.oid"))
    }

    @Test("A partitioned parent carries its partition count with the listing")
    func listingProjectsPartitionCount() {
        let query = awareQuery()
        #expect(query.contains("FROM pg_catalog.pg_inherits ci"))
        #expect(query.contains("ci.inhparent = pc.oid"))
        #expect(query.contains("AS partition_count"))
    }

    @Test("Dropping partition awareness drops the count with it and keeps the columns aligned")
    func unawareListingStillProjectsFourColumns() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true,
            includePartitionAwareness: false
        )
        #expect(query.contains("NULL::bigint AS partition_count"))
        #expect(!query.contains("pg_catalog.pg_inherits"))
        let countColumns = query.components(separatedBy: "AS partition_count").count - 1
        let branches = query.components(separatedBy: "UNION ALL").count
        #expect(countColumns == branches)
    }

    @Test("Partition listing is scoped to one parent in one schema")
    func fetchPartitionsScopesToParent() {
        let query = PostgreSQLSchemaQueries.fetchPartitions(schema: "public", table: "orders")
        #expect(query.contains("pn.nspname = 'public'"))
        #expect(query.contains("parent.relname = 'orders'"))
        #expect(query.contains("parent.relkind = 'p'"))
    }

    @Test("Partition listing sorts the DEFAULT partition last")
    func fetchPartitionsSortsDefaultLast() {
        let query = PostgreSQLSchemaQueries.fetchPartitions(schema: "public", table: "orders")
        #expect(query.contains("ORDER BY pg_catalog.pg_get_expr(cc.relpartbound, cc.oid) = 'DEFAULT', cc.relname"))
    }

    @Test("Partition listing projects relkind so subpartitioned children stay expandable")
    func fetchPartitionsProjectsRelkind() {
        let query = PostgreSQLSchemaQueries.fetchPartitions(schema: "public", table: "orders")
        #expect(query.contains("SELECT cc.relname, cc.relkind"))
    }

    @Test("Partition listing projects the child's own namespace, not the parent's")
    func fetchPartitionsProjectsChildNamespace() {
        let query = PostgreSQLSchemaQueries.fetchPartitions(schema: "public", table: "orders")
        #expect(query.contains("JOIN pg_catalog.pg_namespace cn ON cn.oid = cc.relnamespace"))
        #expect(query.contains("cn.nspname"))
    }

    @Test("Partition listing projects the bound and the row estimate")
    func fetchPartitionsProjectsBoundAndRows() {
        let query = PostgreSQLSchemaQueries.fetchPartitions(schema: "public", table: "orders")
        #expect(query.contains("pg_catalog.pg_get_expr(cc.relpartbound, cc.oid) AS partition_bound"))
        #expect(query.contains("cc.reltuples::bigint AS approximate_rows"))
    }
}

@Suite("A partition is whatever relkind says it is")
struct PluginPartitionRelationTypeTests {
    @Test("Underscore and lower-case spellings resolve to the same relation")
    func normalisesDeclaredSpellings() {
        #expect(PluginPartitionInfo.relationType(forDeclaredType: "foreign_table") == "FOREIGN TABLE")
        #expect(PluginPartitionInfo.relationType(forDeclaredType: "Partitioned Table") == "PARTITIONED TABLE")
        #expect(PluginPartitionInfo.relationType(forDeclaredType: "TABLE") == "TABLE")
    }

    /// Kafka answers the older requirement with broker partitions typed `partition`. Those are not
    /// relations, and calling one a table would offer to open and drop a name no server accepts.
    @Test("A type that names no relation gets none")
    func rejectsNonRelationTypes() {
        #expect(PluginPartitionInfo.relationType(forDeclaredType: "partition") == nil)
        #expect(PluginPartitionInfo.relationType(forDeclaredType: "") == nil)
    }

    @Test("A partition with no relation type is not addressable")
    func relationFlagFollowsTheType() {
        let intraTable = PluginPartitionInfo(name: "p0", relationType: nil)
        let relation = PluginPartitionInfo(name: "orders_2024", relationType: "TABLE")

        #expect(!intraTable.isSeparateRelation)
        #expect(relation.isSeparateRelation)
    }
}

@Suite("PostgreSQL partition bounds read as the server spells them")
struct PostgreSQLPartitionBoundTests {
    @Test("The FOR VALUES prefix every row repeats is dropped")
    func stripsSharedPrefix() {
        #expect(
            PostgreSQLPartitionBound.display(
                rawExpression: "FOR VALUES FROM ('2024-01-01') TO ('2024-02-01')"
            ) == "FROM ('2024-01-01') TO ('2024-02-01')"
        )
        #expect(
            PostgreSQLPartitionBound.display(rawExpression: "FOR VALUES IN ('de', 'fr', 'es')")
                == "IN ('de', 'fr', 'es')"
        )
        #expect(
            PostgreSQLPartitionBound.display(rawExpression: "FOR VALUES WITH (modulus 4, remainder 0)")
                == "WITH (modulus 4, remainder 0)"
        )
    }

    @Test("DEFAULT carries no prefix and is left alone")
    func keepsDefaultWhole() {
        #expect(PostgreSQLPartitionBound.display(rawExpression: "DEFAULT") == "DEFAULT")
    }

    @Test("A legacy INHERITS child reports no bound at all")
    func reportsNoBoundForInheritsChild() {
        #expect(PostgreSQLPartitionBound.display(rawExpression: nil) == nil)
        #expect(PostgreSQLPartitionBound.display(rawExpression: "   ") == nil)
    }

    @Test("A bound that is only the prefix keeps the whole text rather than emptying")
    func keepsPrefixOnlyExpression() {
        #expect(PostgreSQLPartitionBound.display(rawExpression: "FOR VALUES ") == "FOR VALUES")
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
