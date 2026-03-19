//
//  CloudflareD1PluginMetadataTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro
import TableProPluginKit

@Suite("Cloudflare D1 Plugin Metadata")
struct CloudflareD1PluginMetadataTests {

    // MARK: - DatabaseType

    @Test("DatabaseType.cloudflareD1 has correct rawValue")
    func databaseTypeRawValue() {
        #expect(DatabaseType.cloudflareD1.rawValue == "Cloudflare D1")
    }

    @Test("DatabaseType.cloudflareD1 equals itself")
    func databaseTypeEquality() {
        #expect(DatabaseType.cloudflareD1 == DatabaseType(rawValue: "Cloudflare D1"))
    }

    @Test("DatabaseType.cloudflareD1 differs from SQLite")
    func databaseTypeDiffers() {
        #expect(DatabaseType.cloudflareD1 != DatabaseType.sqlite)
    }

    // MARK: - Registry Defaults

    @Test("Registry defaults include Cloudflare D1 entry")
    func registryDefaultsIncludeD1() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        let d1Entry = defaults.first { $0.typeId == "Cloudflare D1" }
        #expect(d1Entry != nil)
    }

    @Test("D1 registry entry has correct display name")
    func registryDisplayName() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        guard let d1Entry = defaults.first(where: { $0.typeId == "Cloudflare D1" }) else {
            Issue.record("Cloudflare D1 not found in registry defaults")
            return
        }
        #expect(d1Entry.snapshot.displayName == "Cloudflare D1")
    }

    @Test("D1 registry entry has correct brand color")
    func registryBrandColor() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        guard let d1Entry = defaults.first(where: { $0.typeId == "Cloudflare D1" }) else {
            Issue.record("Cloudflare D1 not found in registry defaults")
            return
        }
        #expect(d1Entry.snapshot.brandColorHex == "#F6821F")
    }

    @Test("D1 registry entry is downloadable")
    func registryIsDownloadable() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        guard let d1Entry = defaults.first(where: { $0.typeId == "Cloudflare D1" }) else {
            Issue.record("Cloudflare D1 not found in registry defaults")
            return
        }
        #expect(d1Entry.snapshot.isDownloadable)
    }

    @Test("D1 registry entry does not support SSH or SSL")
    func registryNoSSHSSL() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        guard let d1Entry = defaults.first(where: { $0.typeId == "Cloudflare D1" }) else {
            Issue.record("Cloudflare D1 not found in registry defaults")
            return
        }
        #expect(!d1Entry.snapshot.capabilities.supportsSSH)
        #expect(!d1Entry.snapshot.capabilities.supportsSSL)
    }

    @Test("D1 registry entry supports database switching")
    func registryDatabaseSwitching() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        guard let d1Entry = defaults.first(where: { $0.typeId == "Cloudflare D1" }) else {
            Issue.record("Cloudflare D1 not found in registry defaults")
            return
        }
        #expect(d1Entry.snapshot.supportsDatabaseSwitching)
    }

    @Test("D1 registry entry uses flat grouping")
    func registryFlatGrouping() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        guard let d1Entry = defaults.first(where: { $0.typeId == "Cloudflare D1" }) else {
            Issue.record("Cloudflare D1 not found in registry defaults")
            return
        }
        #expect(d1Entry.snapshot.schema.databaseGroupingStrategy == .flat)
    }

    @Test("D1 registry entry has SQL dialect with double-quote identifier")
    func registryDialectQuote() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        guard let d1Entry = defaults.first(where: { $0.typeId == "Cloudflare D1" }) else {
            Issue.record("Cloudflare D1 not found in registry defaults")
            return
        }
        #expect(d1Entry.snapshot.editor.sqlDialect?.identifierQuote == "\"")
    }

    @Test("D1 registry entry has SQLite-compatible keywords")
    func registryDialectKeywords() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        guard let d1Entry = defaults.first(where: { $0.typeId == "Cloudflare D1" }) else {
            Issue.record("Cloudflare D1 not found in registry defaults")
            return
        }
        guard let dialect = d1Entry.snapshot.editor.sqlDialect else {
            Issue.record("Expected SQL dialect")
            return
        }
        #expect(dialect.keywords.contains("PRAGMA"))
        #expect(dialect.keywords.contains("AUTOINCREMENT"))
        #expect(dialect.keywords.contains("VACUUM"))
    }

    @Test("D1 registry entry has EXPLAIN QUERY PLAN variant")
    func registryExplainVariant() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        guard let d1Entry = defaults.first(where: { $0.typeId == "Cloudflare D1" }) else {
            Issue.record("Cloudflare D1 not found in registry defaults")
            return
        }
        #expect(d1Entry.snapshot.explainVariants.count == 1)
        #expect(d1Entry.snapshot.explainVariants.first?.sqlPrefix == "EXPLAIN QUERY PLAN")
    }

    @Test("D1 registry entry has cfAccountId connection field")
    func registryConnectionField() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        guard let d1Entry = defaults.first(where: { $0.typeId == "Cloudflare D1" }) else {
            Issue.record("Cloudflare D1 not found in registry defaults")
            return
        }
        let fields = d1Entry.snapshot.connection.additionalConnectionFields
        #expect(fields.count == 1)
        #expect(fields.first?.id == "cfAccountId")
        #expect(fields.first?.isRequired == true)
        #expect(fields.first?.section == .authentication)
    }

    @Test("D1 registry entry uses question mark parameter style")
    func registryParameterStyle() {
        let registry = PluginMetadataRegistry.shared
        let defaults = registry.registryPluginDefaults()
        guard let d1Entry = defaults.first(where: { $0.typeId == "Cloudflare D1" }) else {
            Issue.record("Cloudflare D1 not found in registry defaults")
            return
        }
        #expect(d1Entry.snapshot.parameterStyle == .questionMark)
    }
}
