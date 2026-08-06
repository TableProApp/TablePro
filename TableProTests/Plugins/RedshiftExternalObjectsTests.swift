//
//  RedshiftExternalObjectsTests.swift
//  TableProTests
//
//  Tests for the Redshift external catalog query builders and row classifiers
//  (compiled via symlink from PostgreSQLDriverPlugin). Regression cover for
//  external schemas whose tables live only in SVV_EXTERNAL_TABLES, so a
//  listing built on information_schema showed the schema as empty.
//

import Foundation
import Testing

@Suite("RedshiftExternalSchemaQueries")
struct RedshiftExternalSchemaQueriesTests {
    private var allQueries: [String] {
        [
            RedshiftExternalSchemaQueries.listExternalSchemaNames,
            RedshiftExternalSchemaQueries.listExternalTables(schemaLiteral: "etl", databaseLiteral: "dev"),
            RedshiftExternalSchemaQueries.listExternalColumns(
                schemaLiteral: "etl",
                tableLiteral: "customers",
                databaseLiteral: "dev"
            ),
            RedshiftExternalSchemaQueries.listExternalColumns(
                schemaLiteral: "etl",
                tableLiteral: nil,
                databaseLiteral: "dev"
            ),
        ]
    }

    @Test("no query mixes a leader-node-only function with an svv_ view")
    func noLeaderNodeOnlyFunctions() {
        for query in allQueries {
            let lowered = query.lowercased()
            #expect(!lowered.contains("has_schema_privilege"))
            #expect(!lowered.contains("has_table_privilege"))
            #expect(!lowered.contains("has_database_privilege"))
            #expect(!lowered.contains("current_schema"))
            #expect(!lowered.contains("substr"))
            #expect(!lowered.contains("version()"))
        }
    }

    @Test("schema listing reads svv_external_schemas unfiltered")
    func schemaListingReadsExternalSchemas() {
        let query = RedshiftExternalSchemaQueries.listExternalSchemaNames
        #expect(query.contains("svv_external_schemas"))
        #expect(query.contains("schemaname"))
    }

    @Test("table listing filters on the requested schema and orders by name")
    func tableListingFiltersOnSchema() {
        let query = RedshiftExternalSchemaQueries.listExternalTables(schemaLiteral: "etl", databaseLiteral: "dev")
        #expect(query.contains("FROM svv_external_tables"))
        #expect(query.contains("WHERE schemaname = 'etl'"))
        #expect(query.contains("ORDER BY tablename"))
        #expect(query.contains("tabletype"))
    }

    @Test("every external catalog read is scoped to the connected database")
    func externalReadsAreScopedToDatabase() {
        let tables = RedshiftExternalSchemaQueries.listExternalTables(schemaLiteral: "etl", databaseLiteral: "dev")
        #expect(tables.contains("redshift_database_name = 'dev'"))

        let single = RedshiftExternalSchemaQueries.listExternalColumns(
            schemaLiteral: "etl",
            tableLiteral: "customers",
            databaseLiteral: "dev"
        )
        #expect(single.contains("redshift_database_name = 'dev'"))

        let all = RedshiftExternalSchemaQueries.listExternalColumns(
            schemaLiteral: "etl",
            tableLiteral: nil,
            databaseLiteral: "dev"
        )
        #expect(all.contains("redshift_database_name = 'dev'"))
    }

    @Test("single-table column query filters on the table and orders by column number")
    func singleTableColumnQuery() {
        let query = RedshiftExternalSchemaQueries.listExternalColumns(
            schemaLiteral: "etl",
            tableLiteral: "customers",
            databaseLiteral: "dev"
        )
        #expect(query.contains("FROM svv_external_columns"))
        #expect(query.contains("WHERE schemaname = 'etl'"))
        #expect(query.contains("AND tablename = 'customers'"))
        #expect(query.contains("ORDER BY columnnum"))
        #expect(query.contains("external_type"))
        #expect(query.contains("part_key"))
    }

    @Test("all-tables column query prefixes tablename and omits the table filter")
    func allTablesColumnQuery() {
        let query = RedshiftExternalSchemaQueries.listExternalColumns(
            schemaLiteral: "etl",
            tableLiteral: nil,
            databaseLiteral: "dev"
        )
        #expect(query.contains("tablename,"))
        #expect(!query.contains("AND tablename ="))
        #expect(query.contains("ORDER BY tablename, columnnum"))
    }

    @Test("escaped schema literals reach the generated SQL intact")
    func escapedLiteralsAreInterpolated() {
        let query = RedshiftExternalSchemaQueries.listExternalTables(
            schemaLiteral: "o''brien",
            databaseLiteral: "d''ev"
        )
        #expect(query.contains("WHERE schemaname = 'o''brien'"))
        #expect(query.contains("redshift_database_name = 'd''ev'"))
    }
}

@Suite("RedshiftExternalSchemaQueries.classifyTableType")
struct RedshiftExternalTableTypeTests {
    @Test("a table stays an external table")
    func tableIsExternalTable() {
        #expect(RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: "TABLE") == "EXTERNAL TABLE")
    }

    @Test("a view maps onto the existing read-only view kind")
    func viewMapsToView() {
        #expect(RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: "VIEW") == "VIEW")
    }

    @Test("tabletype casing varies across Redshift views and is matched loosely")
    func viewCasingIsNormalized() {
        #expect(RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: "view") == "VIEW")
        #expect(RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: " View ") == "VIEW")
    }

    @Test("a materialized view stays an external table rather than a hidden bucket")
    func materializedViewIsExternalTable() {
        #expect(
            RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: "MATERIALIZED VIEW") == "EXTERNAL TABLE"
        )
    }

    @Test("a blank tabletype is kept as an external table instead of being dropped")
    func blankTabletypeIsKept() {
        #expect(RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: " ") == "EXTERNAL TABLE")
        #expect(RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: "") == "EXTERNAL TABLE")
    }

    @Test("a missing tabletype is kept as an external table")
    func missingTabletypeIsKept() {
        #expect(RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: nil) == "EXTERNAL TABLE")
    }
}

@Suite("RedshiftExternalSchemaQueries column classifiers")
struct RedshiftExternalColumnClassifierTests {
    @Test("only an explicit false marks a column required")
    func nullabilityDefaultsToPermissive() {
        #expect(RedshiftExternalSchemaQueries.classifyIsNullable(raw: "true"))
        #expect(RedshiftExternalSchemaQueries.classifyIsNullable(raw: "TRUE"))
        #expect(!RedshiftExternalSchemaQueries.classifyIsNullable(raw: "false"))
        #expect(!RedshiftExternalSchemaQueries.classifyIsNullable(raw: "FALSE"))
    }

    @Test("an unknown nullability is treated as nullable")
    func unknownNullabilityIsNullable() {
        #expect(RedshiftExternalSchemaQueries.classifyIsNullable(raw: " "))
        #expect(RedshiftExternalSchemaQueries.classifyIsNullable(raw: nil))
    }

    @Test("a positive part_key describes its position in the partition key")
    func partitionKeyPositionIsDescribed() {
        #expect(RedshiftExternalSchemaQueries.partitionKeyDescription(rawPartKey: "1") == "PARTITION KEY 1")
        #expect(RedshiftExternalSchemaQueries.partitionKeyDescription(rawPartKey: "2") == "PARTITION KEY 2")
    }

    @Test("an ordinary column carries no partition marker")
    func ordinaryColumnHasNoPartitionMarker() {
        #expect(RedshiftExternalSchemaQueries.partitionKeyDescription(rawPartKey: "0") == nil)
        #expect(RedshiftExternalSchemaQueries.partitionKeyDescription(rawPartKey: " ") == nil)
        #expect(RedshiftExternalSchemaQueries.partitionKeyDescription(rawPartKey: nil) == nil)
    }
}
