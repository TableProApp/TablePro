//
//  PluginManagerEditorMetadataTests.swift
//  TableProTests
//
//  A variant type (Redshift, CockroachDB, PGlite on the PostgreSQL plugin) has its own
//  curated snapshot, so the editor must read the variant's entry. Looking it up by plugin
//  type instead handed a Redshift tab PostgreSQL's dialect, which is where its ASCII-only
//  ILIKE came from.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("PluginManager editor metadata")
@MainActor
struct PluginManagerEditorMetadataTests {
    @Test("a variant type resolves its own dialect rather than the primary plugin's")
    func variantDialectWinsOverPrimary() throws {
        let redshift = try #require(PluginManager.shared.sqlDialect(for: .redshift))
        let postgresql = try #require(PluginManager.shared.sqlDialect(for: .postgresql))

        #expect(redshift.caseSensitivityStyle == .caseFoldFunction)
        #expect(postgresql.caseSensitivityStyle == .ilikeOperator)
        #expect(PluginManager.shared.caseSensitivityStyle(for: .redshift) == .caseFoldFunction)
    }

    @Test("a variant type resolves its own identifier quoting")
    func variantQuotingComesFromItsOwnEntry() throws {
        let mariadb = try #require(PluginManager.shared.sqlDialect(for: .mariadb))
        #expect(mariadb.identifierQuote == "`")
    }

    @Test("a type with no snapshot of its own falls back to its plugin type")
    func unknownVariantFallsBackToPluginSnapshot() throws {
        let aliasTypeId = "PluginManagerEditorMetadataTestsFork"
        let alias = DatabaseType(rawValue: aliasTypeId)
        #expect(PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: aliasTypeId) == nil)

        PluginMetadataRegistry.shared.registerTypeAlias(aliasTypeId, primaryTypeId: "MySQL")
        defer { PluginMetadataRegistry.shared.removeTypeAlias(aliasTypeId) }

        let dialect = try #require(PluginManager.shared.sqlDialect(for: alias))
        #expect(dialect.identifierQuote == "`")
        #expect(PluginManager.shared.editorLanguage(for: alias) == .sql)
    }
}
