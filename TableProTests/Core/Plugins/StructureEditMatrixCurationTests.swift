//
//  StructureEditMatrixCurationTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

/// The matrix is a curated per-engine capability with no `DriverPlugin` static behind it, so it has to
/// survive `buildMetadataSnapshot` the way every other curated capability does. A capability reset to
/// its struct default the moment a plugin loaded is what silently disabled MongoDB's database-scoped
/// authentication (#1970), and the same shape here would put the Structure tab's whole per-kind gate
/// back to tables only for every build with the PostgreSQL plugin installed. (#2726)
@Suite("Structure Edit Matrix Curation")
@MainActor
struct StructureEditMatrixCurationTests {
    @Test("PostgreSQL is curated with the measured per-kind matrix")
    func postgresIsCurated() {
        let matrix = PluginManager.shared.structureEditMatrix(for: .postgresql)
        #expect(StructureEditEligibility.allows(.addIndex, on: .materializedView, matrix: matrix))
        #expect(!StructureEditEligibility.allows(.setDefault, on: .materializedView, matrix: matrix))
        #expect(StructureEditEligibility.allows(.setDefault, on: .view, matrix: matrix))
        #expect(!StructureEditEligibility.allows(.addColumn, on: .view, matrix: matrix))
    }

    /// Conservative on purpose. An engine nobody has measured must never be offered an edit on
    /// anything but a table, so the fallback is `.tablesOnly` rather than another engine's matrix.
    @Test("An engine with no curated entry falls back to tables only")
    func uncuratedEngineFallsBackToTablesOnly() {
        let unknown = DatabaseType(rawValue: "NotARealEngine")
        let matrix = PluginManager.shared.structureEditMatrix(for: unknown)
        #expect(!StructureEditEligibility.allowsAnyEdit(on: .view, matrix: matrix))
        #expect(!StructureEditEligibility.allowsAnyEdit(on: .materializedView, matrix: matrix))
        #expect(StructureEditEligibility.allows(.addColumn, on: .table, matrix: matrix))
    }

    @Test("Every curated engine still offers a table its edits")
    func curatedEnginesKeepTheirTables() {
        for type in DatabaseType.allKnownTypes {
            let matrix = PluginManager.shared.structureEditMatrix(for: type)
            #expect(
                StructureEditEligibility.allowsAnyEdit(on: .table, matrix: matrix),
                "\(type.rawValue) withholds every edit on a plain table"
            )
        }
    }

    @Test("The snapshot's copying helpers carry the matrix across")
    func copyingHelpersPreserveTheMatrix() throws {
        let original = try #require(PluginMetadataRegistry.shared.snapshot(for: .postgresql))
        let expected = original.structureEditing.structureEdits

        let copies: [(String, PluginMetadataSnapshot)] = [
            ("withIconName", original.withIconName("other-icon")),
            ("withExplainVariants", original.withExplainVariants([])),
            ("withBranding", original.withBranding(from: original)),
            ("withIsDownloadable", original.withIsDownloadable(!original.isDownloadable)),
            ("withSwitchRouting", original.withSwitchRouting(from: original))
        ]

        for (name, copy) in copies {
            #expect(copy.structureEditing.structureEdits == expected, "\(name) reset the per-kind matrix")
        }
    }
}
