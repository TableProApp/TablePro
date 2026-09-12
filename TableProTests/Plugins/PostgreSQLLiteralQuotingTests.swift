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
@Suite("PostgreSQL literal quoting")
struct PostgreSQLLiteralQuotingTests {
    private static let caps = PostgreSQLCapabilities.assumingModernWhenUnknown(170_000)

    /// Every pure builder in the plugin that names an object by literal, called with one schema and
    /// one table so a single assertion covers the lot. Redshift and CockroachDB are included: no
    /// server for either was available, and a name with no backslash is byte-identical on both,
    /// which is what makes that safe.
    private static func statements(schema: String, table: String) -> [String] {
        [
            PostgreSQLSchemaQueries.fetchTables(
                schema: schema, includeMaterializedViews: true, includeForeignTables: true
            ),
            PostgreSQLSchemaQueries.fetchPartitions(schema: schema, table: table),
            PostgreSQLSchemaQueries.columnsQuery(
                schema: schema, table: table, capabilities: caps, includeMaterializedViews: true
            ),
            PostgreSQLSchemaQueries.checkConstraintsQuery(schema: schema, table: table),
            PostgreSQLSchemaQueries.allTablesMetadata(schema: schema),
            PostgreSQLObjectQueries.routineList(schema: schema, capabilities: caps),
            PostgreSQLObjectQueries.triggerList(schema: schema, table: table),
            PostgreSQLObjectQueries.routineDefinitionByName(name: table, schema: schema, arguments: nil),
            PostgreSQLObjectQueries.userDefinedTypeList(schema: schema, identity: nil, capabilities: caps),
            PostgreSQLIndexQueries.indexList(schema: schema, table: table),
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
            ColumnQueryShape.primaryKeyJoin(
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

/// Nothing at runtime can see a statement that wraps its own quotes around an already-complete
/// literal: `''E'a\\b''` is valid SQL that matches nothing, and a plain `'\(name)'` only misbehaves
/// on a server running the legacy setting. So the guard is a source scan, the same shape
/// `IndexDDLOwnershipTests` and `SyncMapperFieldAccessTests` use.
@Suite("PostgreSQL literal quoting source scan")
struct PostgreSQLLiteralQuotingSourceScanTests {
    /// `PostgreSQLObjectQueries` owns the quoting and is the one file allowed to write the quotes
    /// itself. `LibPQConnectionString` builds a libpq conninfo string, whose quoting rules are
    /// libpq's rather than SQL's.
    private static let quotingOwners: Set<String> = [
        "PostgreSQLObjectQueries.swift",
        "LibPQConnectionString.swift"
    ]

    /// `LibPQDriverCore` carries the `escapeStringLiteral` PluginKit requirement, whose contract is
    /// inner text for the app and the export plugins to wrap in their own quotes, and
    /// `LibPQStringConformance` implements it. Both read the session's reported
    /// `standard_conforming_strings`, so neither may be reached from a statement builder.
    private static let escapeHelperOwners: Set<String> = [
        "LibPQDriverCore.swift",
        "LibPQStringConformance.swift"
    ]

    private static let pluginDirectory: URL? = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { directory.deleteLastPathComponent() }
        let plugin = directory
            .appendingPathComponent("Plugins")
            .appendingPathComponent("PostgreSQLDriverPlugin")
        return FileManager.default.fileExists(atPath: plugin.path) ? plugin : nil
    }()

    private static func sources() throws -> [(name: String, text: String)] {
        guard let pluginDirectory else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: pluginDirectory, includingPropertiesForKeys: nil)
        return try files
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("The scan reaches the plugin sources at all")
    func sourcesAreReachable() throws {
        let sources = try Self.sources()
        #expect(!sources.isEmpty, "No PostgreSQL plugin sources found; the guards below would pass vacuously")
        #expect(sources.contains { $0.name == "PostgreSQLObjectQueries.swift" })
        #expect(Self.escapeHelperOwners.isSubset(of: Set(sources.map(\.name))))
    }

    /// A line carrying `message:` is a Swift diagnostic quoting a name for the reader, not SQL.
    @Test("No file builds a SQL literal by hand")
    func noHandWrittenLiterals() throws {
        var offenders: [String] = []
        for source in try Self.sources() where !Self.quotingOwners.contains(source.name) {
            for (offset, line) in source.text.components(separatedBy: "\n").enumerated()
            where line.contains(#"'\("#) && !line.contains("message:") {
                offenders.append("\(source.name):\(offset + 1)")
            }
        }

        #expect(
            offenders.isEmpty,
            "These lines quote a literal themselves instead of calling quoteLiteral: \(offenders)"
        )
    }

    @Test("No file builds catalog SQL through a session-dependent escape helper")
    func noSessionDependentEscapeHelpers() throws {
        let helpers = ["escapeLiteral(", "escapeStringLiteral(", "LibPQStringConformance.escape("]
        var offenders: [String] = []
        for source in try Self.sources() where !Self.escapeHelperOwners.contains(source.name) {
            for helper in helpers where source.text.contains(helper) {
                offenders.append("\(source.name): \(helper)")
            }
        }

        #expect(
            offenders.isEmpty,
            "These files reach for an escape helper instead of quoteLiteral: \(offenders)"
        )
    }
}
