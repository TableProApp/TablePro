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
            ("withSwitchRouting", original.withSwitchRouting(from: original))
        ]

        for (name, copy) in copies {
            #expect(copy.structureEditing == expected, "\(name) reset the structure-editing capabilities")
        }
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
