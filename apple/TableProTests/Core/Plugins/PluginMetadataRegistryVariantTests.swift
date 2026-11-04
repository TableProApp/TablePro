//
//  PluginMetadataRegistryVariantTests.swift
//  TableProTests
//
//  A multi-type plugin (PostgreSQL serves Redshift, CockroachDB, PGlite) has one set of
//  Swift statics, so per-type facts live only in the curated built-in table. registerVariant
//  must keep the curated entry rather than overwrite it with the shared plugin snapshot.
//
//  The editor config is the exception: the curated one is a stub for the window before any
//  plugin loads, so a variant takes the plugin's grammar and keeps only the editor facts its
//  curated entry states deliberately. No plugin loads under XCTest (AppDelegate guards
//  loadPlugins on XCTestConfigurationFilePath), so these tests hand registerVariant a synthetic
//  snapshot rather than waiting for a real one.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("PluginMetadataRegistry variant registration", .serialized)
struct PluginMetadataRegistryVariantTests {
    @Test("keeps the curated port instead of the shared plugin's")
    func keepsCuratedPort() throws {
        let registry = PluginMetadataRegistry.shared
        let postgres = try #require(registry.snapshot(forRegisteredTypeId: "PostgreSQL"))
        #expect(postgres.defaultPort == 5_432)

        registry.registerVariant(pluginSnapshot: postgres, forTypeId: "CockroachDB", primaryTypeId: "PostgreSQL")

        #expect(registry.snapshot(forRegisteredTypeId: "CockroachDB")?.defaultPort == 26_257)
    }

    @Test("keeps curated capabilities instead of the shared plugin's")
    func keepsCuratedCapabilities() throws {
        let registry = PluginMetadataRegistry.shared
        let postgres = try #require(registry.snapshot(forRegisteredTypeId: "PostgreSQL"))
        #expect(postgres.capabilities.supportsAddColumn == true)

        registry.registerVariant(pluginSnapshot: postgres, forTypeId: "CockroachDB", primaryTypeId: "PostgreSQL")

        #expect(registry.snapshot(forRegisteredTypeId: "CockroachDB")?.capabilities.supportsAddColumn == false)
    }

    @Test("keeps PGlite's single-connection flag through registration")
    func keepsPGliteSingleConnection() throws {
        let registry = PluginMetadataRegistry.shared
        let postgres = try #require(registry.snapshot(forRegisteredTypeId: "PostgreSQL"))
        #expect(postgres.capabilities.supportsConnectionPooling == true)

        registry.registerVariant(pluginSnapshot: postgres, forTypeId: "PGlite", primaryTypeId: "PostgreSQL")

        #expect(registry.snapshot(forRegisteredTypeId: "PGlite")?.capabilities.supportsConnectionPooling == false)
        #expect(registry.snapshot(forRegisteredTypeId: "PGlite")?.connection.defaultHost == "127.0.0.1")
    }

    /// The curated dialect is a stub of about 84 keywords; the PostgreSQL plugin ships 559 plus
    /// an operator set. Reading the curated one handed Redshift, CockroachDB and PGlite a
    /// fraction of their own grammar.
    @Test("a variant takes the plugin's grammar")
    func variantTakesThePluginGrammar() throws {
        let registry = PluginMetadataRegistry.shared
        var pluginSnapshot = try #require(registry.snapshot(forRegisteredTypeId: "PostgreSQL"))
        pluginSnapshot.editor.sqlDialect = Self.syntheticDialect(caseSensitivityStyle: .ilikeOperator)
        defer { registry.unregister(typeId: "CockroachDB") }

        registry.registerVariant(
            pluginSnapshot: pluginSnapshot,
            forTypeId: "CockroachDB",
            primaryTypeId: "PostgreSQL"
        )

        let dialect = try #require(registry.snapshot(forRegisteredTypeId: "CockroachDB")?.editor.sqlDialect)
        #expect(dialect.keywords.contains("SYNTHETIC_KEYWORD"))
        #expect(dialect.operators.map(\.symbol) == ["@@"])
        #expect(dialect.caseSensitivityStyle == .ilikeOperator)
    }

    /// Redshift's ILIKE folds ASCII only, so its curated entry says caseFoldFunction where
    /// PostgreSQL's says ilikeOperator. That override has to survive taking the plugin's grammar.
    @Test("a variant keeps the case sensitivity its curated entry states")
    func variantKeepsCuratedCaseSensitivity() throws {
        let registry = PluginMetadataRegistry.shared
        var pluginSnapshot = try #require(registry.snapshot(forRegisteredTypeId: "PostgreSQL"))
        pluginSnapshot.editor.sqlDialect = Self.syntheticDialect(caseSensitivityStyle: .ilikeOperator)
        defer { registry.unregister(typeId: "Redshift") }

        registry.registerVariant(
            pluginSnapshot: pluginSnapshot,
            forTypeId: "Redshift",
            primaryTypeId: "PostgreSQL"
        )

        let dialect = try #require(registry.snapshot(forRegisteredTypeId: "Redshift")?.editor.sqlDialect)
        #expect(dialect.keywords.contains("SYNTHETIC_KEYWORD"))
        #expect(dialect.caseSensitivityStyle == .caseFoldFunction)
    }

    @Test("Presto keeps a bare LIMIT when the Trino plugin's grammar pages with OFFSET and FETCH")
    func prestoKeepsLimitPaging() throws {
        let registry = PluginMetadataRegistry.shared
        var pluginSnapshot = try #require(registry.snapshot(forRegisteredTypeId: "Trino"))
        pluginSnapshot.editor.sqlDialect = Self.syntheticDialect(
            caseSensitivityStyle: .regexFlag,
            paginationStyle: .offsetFetch
        )
        defer { registry.unregister(typeId: "Presto") }

        registry.registerVariant(pluginSnapshot: pluginSnapshot, forTypeId: "Presto", primaryTypeId: "Trino")

        let presto = try #require(registry.snapshot(for: .presto))
        let dialect = try #require(presto.editor.sqlDialect)
        #expect(dialect.keywords.contains("SYNTHETIC_KEYWORD"))
        #expect(dialect.paginationStyle == .limit)
        #expect(presto.capabilities.pagination == .leadingRowsOnly(maximumRows: nil))
        #expect(presto.displayName == "Presto")
    }

    @Test("Trino keeps paging with OFFSET and FETCH")
    func trinoKeepsOffsetFetch() throws {
        let trino = try #require(PluginMetadataRegistry.shared.snapshot(for: .trino))
        #expect(trino.editor.sqlDialect?.paginationStyle == .offsetFetch)
        #expect(trino.capabilities.pagination == .offset)
    }

    @Test("Presto is offered before its plugin loads, and is served by the Trino plugin")
    func prestoIsATrinoVariant() throws {
        let registry = PluginMetadataRegistry.shared
        let presto = try #require(registry.snapshot(for: .presto))
        #expect(presto.isDownloadable)
        #expect(presto.iconName == "presto-icon")
        #expect(DatabaseType.presto.pluginTypeId == "Trino")
        #expect(registry.databaseType(forUrlScheme: "presto") == .presto)
        #expect(registry.databaseType(forUrlScheme: "trino") == .trino)
    }

    @MainActor
    @Test("A Presto browse reads the leading rows with LIMIT, never OFFSET or FETCH NEXT")
    func prestoBrowseWritesLimitOnly() {
        let builder = TableQueryBuilder(
            databaseType: .presto,
            dialect: PluginManager.shared.sqlDialect(for: .presto),
            pagination: PluginManager.shared.paginationCapability(for: .presto),
            dialectQuote: SQLEscaping.quoteIdentifier
        )
        let query = builder.buildBaseQuery(tableName: "nation", schemaName: "tiny", limit: 1_000, offset: 1_000)
        #expect(query.hasSuffix("LIMIT 1000"))
        #expect(!query.contains("OFFSET"))
        #expect(!query.contains("FETCH"))
    }

    @Test("a variant type resolves its own snapshot, not the plugin type's")
    func variantSnapshotResolvesByRawValue() throws {
        let registry = PluginMetadataRegistry.shared
        #expect(registry.snapshot(for: .redshift)?.defaultPort == 5_439)
        #expect(registry.snapshot(for: .postgresql)?.defaultPort == 5_432)
        #expect(registry.snapshot(for: .cockroachdb)?.defaultPort == 26_257)
        #expect(registry.snapshot(for: .tidb)?.defaultPort == 4_000)
        #expect(registry.snapshot(for: .databend)?.defaultPort == 3_307)
        #expect(registry.snapshot(for: .oceanbase)?.defaultPort == 2_881)
    }

    /// One connection, one dialect. The filter preview reads PluginManager.sqlDialect while the
    /// executed base query builds through resolveSQLDialect, so a variant answering differently
    /// between them shows the user one statement and runs another.
    @MainActor
    @Test("every reader of the editor dialect agrees for a variant type")
    func dialectReadersAgreeForAVariant() throws {
        for databaseType in [DatabaseType.redshift, .cockroachdb, .pglite, .mariadb, .tidb, .databend, .oceanbase] {
            let viaManager = try #require(PluginManager.shared.sqlDialect(for: databaseType))
            let viaHelper = try resolveSQLDialect(for: databaseType)
            #expect(viaManager.caseSensitivityStyle == viaHelper.caseSensitivityStyle)
            #expect(viaManager.identifierQuote == viaHelper.identifierQuote)
            #expect(PluginManager.shared.autoLimitStyle(for: databaseType) == viaManager.autoLimitStyle)
        }
    }

    private static func syntheticDialect(
        caseSensitivityStyle: SQLDialectDescriptor.CaseSensitivityStyle,
        paginationStyle: SQLDialectDescriptor.PaginationStyle = .limit
    ) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: ["SELECT", "SYNTHETIC_KEYWORD"],
            functions: ["SYNTHETIC_FUNCTION"],
            dataTypes: ["SYNTHETIC_TYPE"],
            regexSyntax: .tilde,
            booleanLiteralStyle: .truefalse,
            likeEscapeStyle: .explicit,
            paginationStyle: paginationStyle,
            offsetFetchOrderBy: "",
            caseSensitivityStyle: caseSensitivityStyle,
            operators: [SQLOperatorDescriptor(symbol: "@@", summary: "synthetic", category: .fullText)]
        )
    }
}
