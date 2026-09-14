//
//  PluginMetadataSnapshotCopyTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

/// `PluginMetadataSnapshot` is copied by five helpers that each restate every field by hand, and a
/// field one of them forgets is silently reset to its default rather than failing to compile. That
/// is not hypothetical for this struct: a curated capability being reset the moment a plugin loaded
/// is what silently disabled MongoDB's database-scoped authentication.
///
/// These hold the helpers to carrying the structure-editing capabilities across, which is what
/// decides whether the Structure tab offers a foreign key edit at all.
@Suite("Plugin Metadata Snapshot Copying")
struct PluginMetadataSnapshotCopyTests {
    private var sqliteType: DatabaseType { .sqlite }

    private func snapshot() throws -> PluginMetadataSnapshot {
        try #require(PluginMetadataRegistry.shared.snapshot(for: sqliteType))
    }

    /// Not an arbitrary pair: SQLite is the engine whose foreign key editing depends on it, and a
    /// reset here puts the reported bug back.
    @Test("SQLite is curated as rebuilding the table for both kinds of edit")
    func sqliteDeclaresRebuild() throws {
        let editing = try snapshot().structureEditing
        #expect(editing.foreignKeyEdit == .rebuild)
        #expect(editing.columnReorder == .rebuild)
    }

    @Test("Every copying helper carries the structure-editing capabilities across")
    func copyingHelpersPreserveStructureEditing() throws {
        let original = try snapshot()
        let expected = original.structureEditing

        let copies: [(String, PluginMetadataSnapshot)] = [
            ("withIconName", original.withIconName("other-icon")),
            ("withExplainVariants", original.withExplainVariants([])),
            ("withBranding", original.withBranding(from: original)),
            ("withIsDownloadable", original.withIsDownloadable(!original.isDownloadable)),
            ("withSwitchRouting", original.withSwitchRouting(from: original)),
            ("withSystemNames", original.withSystemNames(databases: [], schemas: []))
        ]

        for (name, copy) in copies {
            #expect(copy.structureEditing == expected, "\(name) reset the structure-editing capabilities")
        }
    }

    @Test("Every copying helper carries the implicit schema across")
    func copyingHelpersPreserveImplicitSchema() throws {
        let original = try #require(PluginMetadataRegistry.shared.snapshot(for: .spanner))

        let copies: [(String, PluginMetadataSnapshot)] = [
            ("withIconName", original.withIconName("other-icon")),
            ("withExplainVariants", original.withExplainVariants([])),
            ("withBranding", original.withBranding(from: original)),
            ("withIsDownloadable", original.withIsDownloadable(!original.isDownloadable)),
            ("withSwitchRouting", original.withSwitchRouting(from: original)),
            ("withSystemNames", original.withSystemNames(databases: [], schemas: []))
        ]

        for (name, copy) in copies {
            #expect(copy.schema.implicitSchemaName == "(default)", "\(name) reset the implicit schema")
        }
    }

    @Test("withSystemNames replaces only the two system name lists")
    func withSystemNamesKeepsEveryOtherSchemaField() throws {
        let original = try #require(PluginMetadataRegistry.shared.snapshot(for: .mysql))
        let copy = original.withSystemNames(databases: ["a"], schemas: ["b"])

        #expect(copy.schema.systemDatabaseNames == ["a"])
        #expect(copy.schema.systemSchemaNames == ["b"])
        #expect(copy.schema.defaultSchemaName == original.schema.defaultSchemaName)
        #expect(copy.schema.containerEntityName == original.schema.containerEntityName)
        #expect(copy.schema.databaseGroupingStrategy == original.schema.databaseGroupingStrategy)
        #expect(copy.schema.structureColumnFields == original.schema.structureColumnFields)
        #expect(copy.schema.rowMatchTextTypePrefixes == original.schema.rowMatchTextTypePrefixes)
        #expect(copy.schema.fileSignatures.count == original.schema.fileSignatures.count)
        #expect(copy.editor.columnTypesByCategory == original.editor.columnTypesByCategory)
        #expect(copy.capabilities.supportsSSH == original.capabilities.supportsSSH)
    }

    /// An engine whose `ALTER TABLE` can add a constraint says so, and is not pushed through a
    /// rebuild it does not need.
    @Test("An engine with the statements is curated as altering, not rebuilding")
    func alterEnginesDeclareAlter() throws {
        for type in [DatabaseType.mysql, .postgresql] {
            let snapshot = try #require(PluginMetadataRegistry.shared.snapshot(for: type))
            #expect(snapshot.structureEditing.foreignKeyEdit == .alter, "\(type.rawValue)")
        }
    }
}
