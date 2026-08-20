//
//  FavoritesExpansionStateTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
@Suite("FavoritesExpansionState")
struct FavoritesExpansionStateTests {
    private func makeState() throws -> (FavoritesExpansionState, UserDefaults, String) {
        let suite = "FavoritesExpansionStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (FavoritesExpansionState(defaults: defaults), defaults, suite)
    }

    @Test("A group is expanded until it is collapsed")
    func collapsingAGroup() throws {
        let (state, _, _) = try makeState()
        let connectionId = UUID()

        #expect(state.isDatabaseEnvironmentExpanded(.production, for: connectionId))

        state.setDatabaseEnvironmentExpanded(.production, expanded: false, for: connectionId)
        #expect(!state.isDatabaseEnvironmentExpanded(.production, for: connectionId))
        #expect(state.isDatabaseEnvironmentExpanded(.testing, for: connectionId))
    }

    @Test("Collapsed groups survive a reload")
    func collapsedGroupsPersist() throws {
        let (state, defaults, _) = try makeState()
        let connectionId = UUID()
        state.setDatabaseEnvironmentExpanded(.development, expanded: false, for: connectionId)

        let reloaded = FavoritesExpansionState(defaults: defaults)
        #expect(!reloaded.isDatabaseEnvironmentExpanded(.development, for: connectionId))
    }

    /// The bug: `Set<FavoriteDatabaseEnvironment>` fails the whole payload on one unknown case, so a
    /// build that added an environment and was then rolled back discarded the collapsed state of
    /// every group of every connection, permanently, from the next write onward.
    @Test("One unrecognized environment does not discard the other connections")
    func unknownEnvironmentIsSkipped() throws {
        let known = UUID()
        let partial = UUID()
        let stored: [UUID: Set<String>] = [
            known: ["production"],
            partial: ["staging", "testing"]
        ]

        let decoded = FavoritesExpansionState.decodeCollapsedEnvironments(
            try JSONEncoder().encode(stored)
        )

        #expect(decoded[known] == [.production])
        #expect(decoded[partial] == [.testing])
    }

    @Test("A connection whose every collapsed environment is unknown drops out entirely")
    func fullyUnknownConnectionDropsOut() throws {
        let stored: [UUID: Set<String>] = [UUID(): ["staging"]]

        #expect(
            FavoritesExpansionState
                .decodeCollapsedEnvironments(try JSONEncoder().encode(stored))
                .isEmpty
        )
    }

    @Test("Malformed data reads as no collapsed groups")
    func malformedDataIsEmpty() {
        #expect(FavoritesExpansionState.decodeCollapsedEnvironments(Data("not-json".utf8)).isEmpty)
        #expect(FavoritesExpansionState.decodeCollapsedEnvironments(nil).isEmpty)
    }

    @Test("Deleting a connection forgets its groups and leaves the others alone")
    func removeConnection() throws {
        let (state, _, _) = try makeState()
        let deleted = UUID()
        let kept = UUID()
        state.setDatabaseEnvironmentExpanded(.production, expanded: false, for: deleted)
        state.setDatabaseEnvironmentExpanded(.production, expanded: false, for: kept)

        state.removeConnection(deleted)

        #expect(state.isDatabaseEnvironmentExpanded(.production, for: deleted))
        #expect(!state.isDatabaseEnvironmentExpanded(.production, for: kept))
    }
}
