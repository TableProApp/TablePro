//
//  WindowSidebarStateSeedingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// An all-empty expansion set means "collapsed everything" as much as it means "never
/// opened", so the seed has to record that it ran rather than infer it from emptiness.
@MainActor
@Suite("Sidebar tree expansion seeding")
struct WindowSidebarStateSeedingTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.TablePro.tests.sidebarSeeding.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create a test UserDefaults suite")
        }
        return defaults
    }

    @Test("Seeding opens the browsed database and schema")
    func seedsBrowsedLocation() {
        let state = WindowSidebarState(connectionId: UUID(), defaults: makeDefaults())
        state.seedExpansionIfNeeded(database: "repro", schema: "main")

        #expect(state.expandedTreeDatabases == ["repro"])
        #expect(state.expandedTreeSchemas == ["main"])
        #expect(state.expandedTreeDatabaseSchemas == [DatabaseSchemaKey(database: "repro", schema: "main")])
        #expect(state.didSeedExpansion)
    }

    @Test("A schema-only engine seeds just the schema")
    func seedsSchemaWithoutDatabase() {
        let state = WindowSidebarState(connectionId: UUID(), defaults: makeDefaults())
        state.seedExpansionIfNeeded(database: "", schema: "core")

        #expect(state.expandedTreeDatabases.isEmpty)
        #expect(state.expandedTreeSchemas == ["core"])
        #expect(state.didSeedExpansion)
    }

    /// The outline renders before the connection resolves. Consuming the one shot on that
    /// first empty call would leave the tree closed for the life of the connection.
    @Test("Seeding with nothing to open does not consume the one shot")
    func emptySeedDoesNotConsumeTheShot() {
        let state = WindowSidebarState(connectionId: UUID(), defaults: makeDefaults())

        state.seedExpansionIfNeeded(database: nil, schema: nil)
        #expect(!state.didSeedExpansion)
        state.seedExpansionIfNeeded(database: "", schema: "")
        #expect(!state.didSeedExpansion)

        state.seedExpansionIfNeeded(database: "repro", schema: "main")
        #expect(state.didSeedExpansion)
        #expect(state.expandedTreeDatabases == ["repro"])
    }

    @Test("Seeding runs once, so a later connect cannot reopen what the user closed")
    func seedsOnlyOnce() {
        let state = WindowSidebarState(connectionId: UUID(), defaults: makeDefaults())
        state.seedExpansionIfNeeded(database: "repro", schema: "main")
        state.expandedTreeDatabases = []
        state.expandedTreeSchemas = []
        state.expandedTreeDatabaseSchemas = []

        state.seedExpansionIfNeeded(database: "repro", schema: "main")

        #expect(state.expandedTreeDatabases.isEmpty)
        #expect(state.expandedTreeSchemas.isEmpty)
    }

    @Test("A collapsed-everything tree stays collapsed across a reload")
    func collapsedStateSurvivesReload() {
        let defaults = makeDefaults()
        let connectionId = UUID()

        let first = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        first.seedExpansionIfNeeded(database: "repro", schema: "main")
        first.expandedTreeDatabases = []
        first.expandedTreeSchemas = []
        first.expandedTreeDatabaseSchemas = []

        let second = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(second.didSeedExpansion)
        second.seedExpansionIfNeeded(database: "repro", schema: "main")
        #expect(second.expandedTreeDatabases.isEmpty)
        #expect(second.expandedTreeSchemas.isEmpty)
    }

    @Test("Expansion state persists across a reload")
    func expansionSurvivesReload() {
        let defaults = makeDefaults()
        let connectionId = UUID()

        let first = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        first.seedExpansionIfNeeded(database: "repro", schema: "main")

        let second = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(second.expandedTreeDatabases == ["repro"])
        #expect(second.expandedTreeSchemas == ["main"])
        #expect(second.didSeedExpansion)
    }

    /// A window whose state predates the flag already carries the user's own choices,
    /// so it must not be seeded over.
    @Test("A pre-existing expansion blob counts as already seeded")
    func legacyBlobCountsAsSeeded() throws {
        let defaults = makeDefaults()
        let connectionId = UUID()
        let legacy = """
        {"schemas":["public"],"databases":["app"],"databaseSchemas":[],"tables":[]}
        """
        defaults.set(
            Data(legacy.utf8),
            forKey: "com.TablePro.sidebar.treeExpansion.\(connectionId.uuidString)"
        )

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(state.didSeedExpansion)
        state.seedExpansionIfNeeded(database: "other", schema: "main")
        #expect(state.expandedTreeDatabases == ["app"])
        #expect(state.expandedTreeSchemas == ["public"])
    }
}
