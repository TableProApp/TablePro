//
//  PostgreSQLLiteralQuotingTests.swift
//  TableProTests
//

import Foundation
import Testing

/// Every catalog statement the PostgreSQL-family plugin builds names objects by literal, and a
/// catalog name may legally hold a backslash. With `standard_conforming_strings = off` a backslash
/// inside a plain literal is an escape, so `'a\b'` does not mean `a\b` and `'x\'' OR true--'` ends
/// after `x'` and leaves `OR true` as SQL. Measured on PostgreSQL 17.11: the first returned no rows
/// for a schema holding one table, the second turned a one-row listing into 417 rows, every relation
/// in the database.
///
/// `PostgreSQLObjectQueries.quoteLiteral` is the single answer, and these cases pin both halves of
/// it: an `E''` string whenever the value holds a backslash, and output byte-identical to plain
/// quote doubling whenever it does not.
struct PostgreSQLLiteralQuotingTests {
    private static let caps = PostgreSQLCapabilities.assumingModernWhenUnknown(170_000)

    /// Every pure builder in the plugin that names an object by literal, called with one schema and
    /// one table so a single assertion covers the lot. Redshift and CockroachDB are included: no
    /// server for either was available, and a name with no backslash is byte-identical on both,
    /// which is what makes that safe.
    private static func statements(schema: String, table: String) -> [String] {
        [
            PostgreSQLTableListing.query(
                schema: schema, includeMaterializedViews: true, includeForeignTables: true
            ),
            PostgreSQLTableListing.query(
                in: .schemas([schema, table]), includeMaterializedViews: true, includeForeignTables: true
            ),
            PostgreSQLTableListing.informationSchemaQuery(in: .schemas([schema, table])),
            PostgreSQLSchemaQueries.enumLabelQuery(schema: schema, table: table),
            PostgreSQLSchemaQueries.arrayTypeQuery(schema: schema, table: table),
            PostgreSQLSchemaQueries.databaseMetadata(database: schema),
            PostgreSQLObjectQueries.userDefinedTypeList(schemas: [schema], capabilities: caps),
            CockroachRelationSQL.columnsQuery(schema: schema, table: table),
            PostgreSQLSchemaQueries.fetchPartitions(schema: schema, table: table),
            PostgreSQLSchemaQueries.columnsQuery(
                schema: schema, table: table, capabilities: caps, includeMaterializedViews: true
            ),
            PostgreSQLSchemaQueries.checkConstraintsQuery(schema: schema, table: table),
            PostgreSQLSchemaQueries.allTablesMetadata(schema: schema),
            PostgreSQLSchemaQueries.approximateRowCount(schema: schema, table: table),
            PostgreSQLObjectQueries.routineList(schema: schema, capabilities: caps),
            PostgreSQLObjectQueries.triggerList(schema: schema, table: table),
            PostgreSQLObjectQueries.routineDefinitionByName(name: table, schema: schema, arguments: nil),
            PostgreSQLObjectQueries.userDefinedTypeList(schema: schema, identity: nil, capabilities: caps),
            PostgreSQLIndexQueries.indexList(schema: schema, table: table, capabilities: caps),
            PostgreSQLIndexQueries.indexDDLQuery(schema: schema, table: table),
            PostgreSQLIndexQueries.standaloneIndexQuery(schema: schema, table: table),
            PostgreSQLSchemaQueries.tableDDLConstraintsQuery(schema: schema, table: table),
            PostgreSQLSchemaQueries.tableDDLColumnsQuery(schema: schema, table: table, capabilities: caps),
            PostgreSQLSchemaQueries.rebuildColumnsQuery(schema: schema, table: table, capabilities: caps),
            PostgreSQLForeignKeyQueries.foreignKeyList(schema: schema, table: table, capabilities: caps),
            PostgreSQLSequenceQueries.sequenceList(
                schema: schema, dependentOnTable: table, source: .sequencesView
            ),
            PostgreSQLCatalogForeignKeys.query(schema: schema, table: table, excludesPartitionClones: true),
            PostgreSQLPrincipalQueries.tables(schema: schema),
            PostgreSQLPrincipalQueries.columns(schema: schema, table: table),
            PostgreSQLPrincipalQueries.databaseGrants(role: schema),
            PostgreSQLPrincipalQueries.schemaGrants(role: schema),
            PostgreSQLPrincipalQueries.tableGrants(role: schema),
            PostgreSQLPrincipalQueries.columnGrants(role: schema),
            PostgreSQLPrincipalQueries.ownsObjects(role: schema),
            PostgreSQLRelationSQL.concurrentRefreshQuery(name: table, schema: schema),
            PostgreSQLViewDefinition.catalogQuery(name: table, schema: schema),
            RedshiftSchemaQueries.columnsQuery(schema: schema, table: table),
            RedshiftExternalSchemaQueries.listExternalTables(schema: schema, database: table),
            RedshiftExternalSchemaQueries.listExternalColumns(
                schema: schema, table: table, database: table
            ),
            ColumnQueryShape.informationSchemaPrimaryKeyJoin(
                schema: schema, fragments: ColumnQueryShape.fragments(table: table)
            ),
            ColumnQueryShape.catalogPrimaryKeyJoin(
                schema: schema, fragments: ColumnQueryShape.fragments(table: table)
            )
        ]
    }

    @Test("A backslash in a catalog name is emitted as an E'' literal")
    func backslashNamesBecomeEscapeStrings() {
        for statement in Self.statements(schema: #"a\b"#, table: #"c\d"#) {
            #expect(statement.contains(#"E'a\\b'"#), "No E-string for the schema in: \(statement)")
            #expect(!statement.contains(#"'a\b'"#), "A plain literal survived in: \(statement)")
            #expect(!statement.contains(#"'c\d'"#), "A plain literal survived in: \(statement)")
        }
    }

    @Test("A plain name keeps its plain literal")
    func plainNamesStayPlain() {
        for statement in Self.statements(schema: "s2", table: "orders") {
            #expect(statement.contains("'s2'"), "The schema lost its plain literal in: \(statement)")
        }
    }

    @Test("An apostrophe in a catalog name is doubled and nothing else")
    func apostropheNamesAreDoubled() {
        for statement in Self.statements(schema: "o'brien", table: "d'ev") {
            #expect(statement.contains("'o''brien'"), "The schema lost its doubled quote in: \(statement)")
            #expect(!statement.contains("E'o''brien'"), "An apostrophe took an E-string in: \(statement)")
        }
    }

    /// The blast-radius guard, stated as the property rather than per call site: for any value
    /// holding no backslash, `quoteLiteral` emits exactly what plain quote doubling emitted before
    /// this change, so the only statements that move are the ones that were wrong.
    @Test("A value without a backslash quotes byte-identically to plain quote doubling")
    func quotingIsUnchangedWithoutABackslash() {
        let values = ["", "public", "s2", "orders", "o'brien", "''", "%wild_card%", "Ünïcødé", "a\tb"]
        for value in values {
            let doubled = value.replacingOccurrences(of: "'", with: "''")
            #expect(PostgreSQLObjectQueries.quoteLiteral(value) == "'\(doubled)'")
        }
    }

    /// The injection the probe demonstrated. Quote doubling alone wrote
    /// `schemaname = 'x\'' OR true--'`, whose literal ends after `x'` under the legacy setting, so
    /// `OR true` ran as SQL and the listing returned every relation in the database.
    @Test("A quote after a backslash cannot close the literal")
    func quoteAfterBackslashCannotEscape() {
        let statement = PostgreSQLSchemaQueries.allTablesMetadata(schema: #"x\' OR true--"#)
        #expect(statement.contains(#"E'x\\'' OR true--'"#))
        #expect(!statement.contains(#"'x\'' OR true--'"#))
        #expect(statement.components(separatedBy: "OR true").count == 2)
    }

    /// The wildcards go on before the quoting, because an `E` prefix cannot be spliced into the
    /// middle of a literal.
    @Test("A search pattern is wrapped in its wildcards and then quoted once")
    func searchPatternIsQuotedAsAWhole() {
        #expect(PostgreSQLPrincipalQueries.searchObjects(pattern: "ord", limit: 10).contains("ILIKE '%ord%'"))
        #expect(
            PostgreSQLPrincipalQueries.searchObjects(pattern: #"a\b"#, limit: 10)
                .contains(#"ILIKE E'%a\\b%'"#)
        )
    }

    @Test("A NUL is dropped on both arms rather than reaching libpq")
    func nulIsStripped() {
        #expect(PostgreSQLObjectQueries.quoteLiteral("a\0b") == "'ab'")
        #expect(PostgreSQLObjectQueries.quoteLiteral("a\0\\b") == #"E'a\\b'"#)
        #expect(!PostgreSQLSchemaQueries.allTablesMetadata(schema: "a\0b").contains("\0"))
    }
}
