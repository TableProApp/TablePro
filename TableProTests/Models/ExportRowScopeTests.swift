//
//  ExportRowScopeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Export row scope")
struct ExportRowScopeTests {

    @Test("An empty scope exports everything")
    func emptyScopeIsUnrestricted() {
        #expect(PluginExportRowScope.unrestricted.isUnrestricted)
        #expect(PluginExportRowScope(filter: "  ").isUnrestricted)
    }

    @Test("Any one narrowing makes the scope restricted")
    func anyNarrowingRestricts() {
        #expect(!PluginExportRowScope(filter: "id > 10").isUnrestricted)
        #expect(!PluginExportRowScope(rowLimit: 100).isUnrestricted)
        #expect(!PluginExportRowScope(columns: ["id"]).isUnrestricted)
    }

    /// A trailing semicolon is a typing habit, so it is dropped rather than refusing the filter.
    @Test("A trailing semicolon is dropped")
    func trailingSemicolonIsDropped() {
        let scope = PluginExportRowScope(filter: "status = 'active';")
        #expect(scope.sanitizedFilter == "status = 'active'")
        #expect(!scope.hasRejectedFilter)
    }

    /// The filter is spliced into a SELECT the export builds, so a second statement in it would run
    /// as a second statement. That is refused rather than executed.
    @Test("A semicolon inside the filter refuses the whole filter")
    func interiorSemicolonIsRefused() {
        let scope = PluginExportRowScope(filter: "1 = 1; DROP TABLE users")
        #expect(scope.sanitizedFilter.isEmpty)
        #expect(scope.hasRejectedFilter)
    }

    @Test("A refused filter is reported rather than silently exporting every row")
    func refusedFilterIsReported() {
        #expect(PluginExportRowScope(filter: "a = 1; b = 2").hasRejectedFilter)
        #expect(!PluginExportRowScope(filter: "a = 1").hasRejectedFilter)
        #expect(!PluginExportRowScope(filter: "").hasRejectedFilter)
    }

    @Test("Whitespace around a filter is trimmed")
    func filterIsTrimmed() {
        #expect(PluginExportRowScope(filter: "  id > 5  ").sanitizedFilter == "id > 5")
        #expect(PluginExportRowScope(filter: "\n id > 5 ;\n ").sanitizedFilter == "id > 5")
    }

    @Test("The summary names every narrowing that is set")
    func summaryNamesNarrowings() {
        let scope = PluginExportRowScope(filter: "id > 5", rowLimit: 100, columns: ["id", "name"])
        #expect(scope.summary == "2 columns, WHERE id > 5, LIMIT 100")
        #expect(PluginExportRowScope.unrestricted.summary.isEmpty)
    }

    @Test("A scope survives a round trip through Codable")
    func scopeRoundTrips() throws {
        let scope = PluginExportRowScope(filter: "id > 5", rowLimit: 42, columns: ["a", "b"])
        let decoded = try JSONDecoder().decode(
            PluginExportRowScope.self, from: JSONEncoder().encode(scope))
        #expect(decoded == scope)
    }

    @Test("An export item carries an unrestricted scope unless one is given")
    func exportTableDefaultsToUnrestricted() {
        let table = PluginExportTable(
            name: "users", databaseName: "app", tableType: "table", schema: nil, kind: .table)
        #expect(table.rowScope.isUnrestricted)
    }

    /// The two published initializers cannot gain a parameter without breaking every shipped
    /// plugin, so they have to keep defaulting the field they never knew about.
    @Test("The legacy initializers default the scope")
    func legacyInitializersDefaultTheScope() {
        let withSchema = PluginExportTable(
            name: "users", databaseName: "app", tableType: "table", schema: "public")
        #expect(withSchema.rowScope.isUnrestricted)
        #expect(withSchema.kind == .table)

        let bare = PluginExportTable(name: "v_users", databaseName: "app", tableType: "VIEW")
        #expect(bare.rowScope.isUnrestricted)
        #expect(bare.kind == .view)
    }
}
