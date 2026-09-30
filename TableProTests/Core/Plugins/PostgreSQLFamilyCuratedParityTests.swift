//
//  PostgreSQLFamilyCuratedParityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct PostgreSQLFamilyCuratedParityTests {
    @Test("PGlite reorders columns the way PostgreSQL does, since it runs the same driver")
    func pgliteReordersColumnsLikePostgreSQL() {
        #expect(PluginManager.shared.columnReorderSupport(for: .pglite) == .rebuild)
    }

    @Test("PGlite edits structure the way PostgreSQL does")
    func pgliteStructureEditingMatchesPostgreSQL() throws {
        let postgreSQL = try #require(PluginMetadataRegistry.shared.snapshot(for: .postgresql))
        let pglite = try #require(PluginMetadataRegistry.shared.snapshot(for: .pglite))
        #expect(pglite.structureEditing == postgreSQL.structureEditing)
    }
}
