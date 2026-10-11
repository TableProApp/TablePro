import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLPartitionFilterTests {
    private func awareQuery() -> String {
        PostgreSQLTableListing.query(
            schema: "public",
            includeMaterializedViews: false,
            includeForeignTables: false
        )
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("A partition child is excluded by a per-row probe of pg_inherits on the child's oid")
    func excludesPartitionChildrenPerRow() {
        let query = awareQuery()
        #expect(query.contains("AND NOT EXISTS ("))
        #expect(query.contains("FROM pg_catalog.pg_inherits i"))
        #expect(query.contains("WHERE i.inhrelid = c.oid"))
        #expect(query.contains("        OFFSET 0)"))
        #expect(!query.contains("NOT IN"))
    }

    @Test("Children are matched by their parent relkind, not relispartition")
    func usesParentRelkindNotRelispartition() {
        let query = awareQuery()
        #expect(query.contains("AND parent.relkind = 'p'"))
        #expect(!query.contains("relispartition"))
    }

    @Test("A partitioned parent is labelled instead of reported as a plain base table")
    func labelsPartitionedParent() {
        #expect(awareQuery().contains("CASE c.relkind\n           WHEN 'p' THEN 'PARTITIONED TABLE'\n"))
    }

    @Test("Rows come from pg_class under information_schema.tables' own privilege test")
    func readsPgClassUnderThePrivilegeTest() {
        let query = awareQuery()
        #expect(query.contains("FROM pg_catalog.pg_class rc"))
        #expect(query.contains("AND \(PostgreSQLTableListing.visibleRelation("c"))"))
        #expect(!query.contains("information_schema.tables"))
    }

    @Test("Partition awareness degrades independently of the relation kinds")
    func partitionAwarenessDegradesIndependently() {
        let query = PostgreSQLTableListing.query(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true,
            includePartitionAwareness: false
        )
        #expect(!query.contains("pg_catalog.pg_inherits"))
        #expect(!query.contains("PARTITIONED TABLE"))
        #expect(query.contains("rc.relkind IN ('r', 'p', 'v', 'm', 'f')"))
    }

    @Test("Every relation kind comes from one statement, with no union to keep aligned")
    func listingIsOneStatement() {
        for awareness in [true, false] {
            let query = PostgreSQLTableListing.query(
                schema: "public",
                includeMaterializedViews: true,
                includeForeignTables: true,
                includePartitionAwareness: awareness
            )
            #expect(!query.contains("UNION ALL"))
            #expect(occurrences(of: "AS table_type", in: query) == 1)
            #expect(occurrences(of: "AS table_comment", in: query) == 1)
            #expect(occurrences(of: "AS partition_count", in: query) == 1)
        }
    }

    @Test("A child is dropped only when its own parent passes the same privilege test")
    func excludesOnlyChildrenOfVisibleParents() {
        let query = awareQuery()
        #expect(query.contains("AND NOT pg_catalog.pg_is_other_temp_schema(parent.relnamespace)"))
        #expect(query.contains("AND \(PostgreSQLTableListing.visibleRelation("parent"))\n        OFFSET 0)"))
        #expect(!query.contains("parentns"))
    }

    @Test("A foreign table partition is excluded by the same predicate as any other partition")
    func foreignTablePartitionsShareThePredicate() {
        let query = PostgreSQLTableListing.query(
            schema: "public",
            includeMaterializedViews: false,
            includeForeignTables: true
        )
        #expect(query.contains("WHEN 'f' THEN 'FOREIGN TABLE'"))
        #expect(occurrences(of: "i.inhrelid = c.oid", in: query) == 1)
    }

    @Test("A partitioned parent carries its partition count with the listing")
    func listingProjectsPartitionCount() {
        let query = awareQuery()
        #expect(query.contains("FROM pg_catalog.pg_inherits ci"))
        #expect(query.contains("ci.inhparent = c.oid"))
        #expect(query.contains("AS partition_count"))
    }

    @Test("Dropping partition awareness drops the count with it")
    func unawareListingProjectsNoCount() {
        let query = PostgreSQLTableListing.query(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true,
            includePartitionAwareness: false
        )
        #expect(query.contains("NULL::bigint AS partition_count"))
        #expect(!query.contains("pg_catalog.pg_inherits"))
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

struct PostgreSQLTableListingLadderTests {
    private static let attempts = PostgreSQLTableListingLadder.degradableAttempts
        + [PostgreSQLTableListingLadder.leastCapableAttempt]

    @Test("The catalog form is tried first and information_schema last")
    func ladderRunsFromCatalogsToInformationSchema() {
        #expect(PostgreSQLTableListingLadder.degradableAttempts.allSatisfy { $0.source == .systemCatalogs })
        #expect(PostgreSQLTableListingLadder.degradableAttempts.first?.includeComments == true)
        #expect(PostgreSQLTableListingLadder.leastCapableAttempt.source == .informationSchema)
    }

    @Test("Partition awareness survives every rung that only drops columns")
    func partitionAwarenessDegradesLast() {
        #expect(PostgreSQLTableListingLadder.degradableAttempts.allSatisfy { $0.includePartitionAwareness })
        #expect(!PostgreSQLTableListingLadder.leastCapableAttempt.includePartitionAwareness)
        #expect(!PostgreSQLTableListingLadder.leastCapableAttempt.includeComments)
    }

    @Test("Each rung drops strictly more than the one before it")
    func ladderDegradesMonotonically() {
        let ranks = Self.attempts.map { attempt in
            [attempt.source == .systemCatalogs, attempt.includeComments, attempt.includePartitionAwareness]
                .filter { $0 }.count
        }
        #expect(ranks == ranks.sorted { $0 > $1 })
        #expect(Set(ranks).count == ranks.count)
    }

    @Test("Each rung renders the form its source names")
    func rungsRenderTheirSource() {
        for attempt in Self.attempts {
            let query = PostgreSQLTableListingLadder.query(
                for: attempt, in: .schema("public"), includeMaterializedViews: true, includeForeignTables: true
            )
            #expect(query.contains("information_schema.tables") == (attempt.source == .informationSchema), "\(attempt.label)")
            #expect(query.contains("pg_catalog.pg_description") == attempt.includeComments, "\(attempt.label)")
            #expect(query.contains("pg_catalog.pg_inherits i") == attempt.includePartitionAwareness, "\(attempt.label)")
        }
    }

    @Test("A missing relation, function, column or type degrades the listing; a refusal does not")
    func catalogFailuresDegrade() {
        #expect(PostgreSQLTableListingLadder.isDegradable(sqlState: "42P01"))
        #expect(PostgreSQLTableListingLadder.isDegradable(sqlState: "42883"))
        #expect(PostgreSQLTableListingLadder.isDegradable(sqlState: "42703"))
        #expect(PostgreSQLTableListingLadder.isDegradable(sqlState: "42704"))
        #expect(!PostgreSQLTableListingLadder.isDegradable(sqlState: "28000"))
        #expect(!PostgreSQLTableListingLadder.isDegradable(sqlState: "42501"))
        #expect(!PostgreSQLTableListingLadder.isDegradable(sqlState: nil))
    }
}
