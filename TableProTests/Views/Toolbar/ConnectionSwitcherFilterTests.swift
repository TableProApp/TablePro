//
//  ConnectionSwitcherFilterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProPluginKit
import Testing

struct ConnectionSwitcherFilterTests {
    @Test("Empty or whitespace query matches every connection")
    func emptyQueryMatches() {
        let connection = TestFixtures.makeConnection(name: "Production", database: "app")
        #expect(ConnectionSwitcherFilter.matches(connection, query: ""))
        #expect(ConnectionSwitcherFilter.matches(connection, query: "   "))
    }

    @Test("Name match is case-insensitive and substring-based")
    func nameMatchCaseInsensitive() {
        let connection = TestFixtures.makeConnection(name: "Production DB", database: "app")
        #expect(ConnectionSwitcherFilter.matches(connection, query: "prod"))
        #expect(ConnectionSwitcherFilter.matches(connection, query: "DB"))
    }

    @Test("Database name is searched")
    func databaseMatch() {
        let connection = TestFixtures.makeConnection(name: "Primary", database: "analytics")
        #expect(ConnectionSwitcherFilter.matches(connection, query: "analy"))
    }

    @Test("Host is searched")
    func hostMatch() {
        let connection = TestFixtures.makeConnection(name: "Primary", database: "analytics")
        #expect(ConnectionSwitcherFilter.matches(connection, query: "localhost"))
    }

    @Test("Non-matching query returns false")
    func noMatch() {
        let connection = TestFixtures.makeConnection(name: "Primary", database: "analytics")
        #expect(!ConnectionSwitcherFilter.matches(connection, query: "zzz"))
    }

    @Test("Fuzzy abbreviation matches across word boundaries")
    func fuzzyAbbreviationMatches() {
        let connection = TestFixtures.makeConnection(name: "Production DB", database: "app")
        #expect(ConnectionSwitcherFilter.matches(connection, query: "pdb"))
    }
}

struct ConnectionSwitcherSelectionTests {
    @Test("Empty list yields no selection")
    func emptyList() {
        #expect(ConnectionSwitcherSelection.moved(in: [], from: nil, by: 1) == nil)
    }

    @Test("Moving down advances to the next id")
    func movesDown() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        #expect(ConnectionSwitcherSelection.moved(in: [a, b, c], from: a, by: 1) == b)
        #expect(ConnectionSwitcherSelection.moved(in: [a, b, c], from: b, by: 1) == c)
    }

    @Test("Moving up retreats to the previous id")
    func movesUp() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        #expect(ConnectionSwitcherSelection.moved(in: [a, b, c], from: c, by: -1) == b)
    }

    @Test("Moving past the top clamps to the first id")
    func clampsAtTop() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        #expect(ConnectionSwitcherSelection.moved(in: [a, b, c], from: a, by: -1) == a)
    }

    @Test("Moving past the bottom clamps to the last id")
    func clampsAtBottom() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        #expect(ConnectionSwitcherSelection.moved(in: [a, b, c], from: c, by: 1) == c)
    }
}

struct ConnectionSwitcherSectionsTests {
    private func connection(_ name: String, groupId: UUID? = nil, sortOrder: Int = 0) -> DatabaseConnection {
        DatabaseConnection(name: name, groupId: groupId, sortOrder: sortOrder)
    }

    private func library(
        _ connections: [DatabaseConnection],
        groups: [ConnectionGroup],
        lastConnected: [UUID: Date],
        includesRecent: Bool = true
    ) -> LibraryOutlineRequest<DatabaseConnection, ConnectionGroup, ConnectionTag> {
        LibraryOutlineRequest(
            connections: connections,
            groups: groups,
            tags: [],
            lastConnected: lastConnected,
            includesRecent: includesRecent
        )
    }

    private func titles(_ sections: [FieldDrivenListSection<ConnectionSwitcherEntry>]) -> [String] {
        sections.compactMap(\.title)
    }

    private func names(_ sections: [FieldDrivenListSection<ConnectionSwitcherEntry>]) -> [[String]] {
        sections.map { $0.items.map(\.connection.name) }
    }

    @Test("Saved connections are grouped, and the ones in no group come last")
    func groupsBecomeSections() {
        let acme = ConnectionGroup(name: "Acme", sortOrder: 0)
        let saved = [
            connection("acme-local", groupId: acme.id, sortOrder: 0),
            connection("acme-prod", groupId: acme.id, sortOrder: 1),
            connection("scratch"),
        ]

        let sections = ConnectionSwitcherSections.build(
            active: [], saved: saved, groups: [acme], isFiltering: false
        )

        #expect(titles(sections) == ["ACTIVE CONNECTIONS", "ACME", "UNGROUPED"])
        #expect(names(sections) == [[], ["acme-local", "acme-prod"], ["scratch"]])
    }

    // MARK: - Open without a session

    /// A workspace outlives its session, so a connect that failed, one the user cancelled and an
    /// explicit disconnect all leave a connection open with nothing in `activeSessions`.
    @Test("A hosted connection with no session is still open")
    func hostedWithoutSessionIsOpen() {
        let disconnected = connection("acme-prod")

        let open = ConnectionSwitcherSections.hostedWithoutSession(
            workspaces: [(disconnected.id, disconnected)],
            sessionIds: [],
            saved: [disconnected]
        )

        #expect(open.map(\.id) == [disconnected.id])
    }

    @Test("A connection hosted by two windows is listed once")
    func hostedTwiceIsListedOnce() {
        let detached = connection("acme-prod")

        let open = ConnectionSwitcherSections.hostedWithoutSession(
            workspaces: [(detached.id, detached), (detached.id, detached)],
            sessionIds: [],
            saved: []
        )

        #expect(open.count == 1)
    }

    @Test("A workspace with no record of its own is named by the saved list")
    func aWorkspaceWithoutARecordFallsBackToStorage() {
        let saved = connection("acme-prod")

        let open = ConnectionSwitcherSections.hostedWithoutSession(
            workspaces: [(saved.id, nil)],
            sessionIds: [],
            saved: [saved]
        )

        #expect(open.map(\.name) == ["acme-prod"])
    }

    @Test("A connection that has a session is left to the session list")
    func aSessionBackedConnectionIsNotDuplicated() {
        let live = connection("acme-local")

        let open = ConnectionSwitcherSections.hostedWithoutSession(
            workspaces: [(live.id, live)],
            sessionIds: [live.id],
            saved: [live]
        )

        #expect(open.isEmpty)
    }

    @Test("With no groups at all the saved connections keep their own name")
    func noGroupsKeepsTheSavedHeading() {
        let sections = ConnectionSwitcherSections.build(
            active: [], saved: [connection("scratch")], groups: [], isFiltering: false
        )

        #expect(titles(sections) == ["ACTIVE CONNECTIONS", "SAVED CONNECTIONS"])
    }

    /// The group draws no header once its only connection is open, so the connections beside it
    /// are not "ungrouped" against anything the reader can see.
    @Test("A group whose connections are all open leaves the saved heading alone")
    func anEmptiedGroupDoesNotRenameTheLooseSection() {
        let acme = ConnectionGroup(name: "Acme")
        let open = connection("acme-local", groupId: acme.id)

        let sections = ConnectionSwitcherSections.build(
            active: [ConnectionSwitcherEntry(id: open.id, connection: open, isActive: true, isConnected: true)],
            saved: [connection("scratch")],
            groups: [acme],
            isFiltering: false
        )

        #expect(titles(sections) == ["ACTIVE CONNECTIONS", "SAVED CONNECTIONS"])
    }

    @Test("A nested group names its whole path, under the parent that has connections of its own")
    func nestedGroupNamesItsPath() {
        let acme = ConnectionGroup(name: "Acme")
        let europe = ConnectionGroup(name: "Europe", parentId: acme.id)
        let saved = [
            connection("acme-prod", groupId: acme.id),
            connection("eu-prod", groupId: europe.id),
        ]

        let sections = ConnectionSwitcherSections.build(
            active: [], saved: saved, groups: [acme, europe], isFiltering: false
        )

        #expect(titles(sections) == ["ACTIVE CONNECTIONS", "ACME", "ACME / EUROPE"])
        #expect(names(sections).last == ["eu-prod"])
    }

    /// The parent draws no header of its own, and the child still says where it sits.
    @Test("A group holding only subgroups is named through its children rather than on its own")
    func aParentWithNoConnectionsOfItsOwnIsSkipped() {
        let acme = ConnectionGroup(name: "Acme")
        let europe = ConnectionGroup(name: "Europe", parentId: acme.id)
        let saved = [connection("eu-prod", groupId: europe.id)]

        let sections = ConnectionSwitcherSections.build(
            active: [], saved: saved, groups: [acme, europe], isFiltering: false
        )

        #expect(titles(sections) == ["ACTIVE CONNECTIONS", "ACME / EUROPE"])
    }

    @Test("A group header carries no colored dot, whatever color the group has")
    func groupHeadersHaveNoDot() {
        let coloured = ConnectionGroup(name: "Prod", color: .red)
        let plain = ConnectionGroup(name: "Scratch", sortOrder: 1)

        let sections = ConnectionSwitcherSections.build(
            active: [],
            saved: [connection("a", groupId: coloured.id), connection("b", groupId: plain.id)],
            groups: [coloured, plain],
            isFiltering: false
        )

        #expect(sections.allSatisfy { $0.accentColor == nil })
    }

    @Test("Favorites and recent connections come before the groups and are not repeated in them")
    func favoritesAndRecentLeadTheLibrary() {
        let acme = ConnectionGroup(name: "Acme")
        let favorite = connection("acme-prod", groupId: acme.id)
        let recent = connection("acme-staging", groupId: acme.id)
        let other = connection("acme-local", groupId: acme.id)

        let sections = ConnectionSwitcherSections.build(
            active: [],
            saved: [favorite, recent, other],
            groups: [acme],
            isFiltering: false,
            favorites: [favorite],
            recent: [recent]
        )

        #expect(titles(sections) == ["ACTIVE CONNECTIONS", "FAVORITES", "RECENT", "ACME"])
        #expect(names(sections) == [[], ["acme-prod"], ["acme-staging"], ["acme-local"]])
    }

    @Test("The library's favorites and recent connections lead the groups, newest recent first")
    func libraryShortcutsLeadTheGroups() {
        let acme = ConnectionGroup(name: "Acme")
        var favorite = connection("acme-prod", groupId: acme.id, sortOrder: 0)
        favorite.isFavorite = true
        let older = connection("acme-staging", groupId: acme.id, sortOrder: 1)
        let newer = connection("acme-qa", groupId: acme.id, sortOrder: 2)
        let other = connection("acme-local", groupId: acme.id, sortOrder: 3)

        let sections = ConnectionSwitcherSections.build(
            active: [],
            library: library(
                [favorite, older, newer, other],
                groups: [acme],
                lastConnected: [
                    favorite.id: Date(timeIntervalSince1970: 3),
                    older.id: Date(timeIntervalSince1970: 1),
                    newer.id: Date(timeIntervalSince1970: 2),
                ]
            ),
            isFiltering: false
        )

        #expect(titles(sections) == ["ACTIVE CONNECTIONS", "FAVORITES", "RECENT", "ACME"])
        #expect(names(sections) == [[], ["acme-prod"], ["acme-qa", "acme-staging"], ["acme-local"]])
    }

    @Test("Hiding Recent returns its connections to their normal group")
    func hiddenRecentFallsBackToGroup() {
        let acme = ConnectionGroup(name: "Acme")
        let recent = connection("acme-staging", groupId: acme.id, sortOrder: 0)
        let other = connection("acme-local", groupId: acme.id, sortOrder: 1)

        let sections = ConnectionSwitcherSections.build(
            active: [],
            library: library(
                [recent, other],
                groups: [acme],
                lastConnected: [recent.id: Date()],
                includesRecent: false
            ),
            isFiltering: false
        )

        #expect(titles(sections) == ["ACTIVE CONNECTIONS", "ACME"])
        #expect(names(sections) == [[], ["acme-staging", "acme-local"]])
    }

    @Test("A group nested past the cap still gets a section")
    func deepGroupStillListed() {
        let one = ConnectionGroup(name: "One")
        let two = ConnectionGroup(name: "Two", parentId: one.id)
        let three = ConnectionGroup(name: "Three", parentId: two.id)
        let four = ConnectionGroup(name: "Four", parentId: three.id)
        let five = ConnectionGroup(name: "Five", parentId: four.id)

        let sections = ConnectionSwitcherSections.build(
            active: [],
            saved: [connection("deep", groupId: five.id)],
            groups: [one, two, three, four, five],
            isFiltering: false
        )

        #expect(titles(sections).last == "ONE / TWO / THREE / FOUR / FIVE")
    }

    /// A search is a lookup rather than a browse: one match in each of eight groups would otherwise
    /// be eight one-row sections, and a header cannot be selected to get out of them.
    @Test("A filter collapses the groups back into one saved section")
    func filteringFlattens() {
        let acme = ConnectionGroup(name: "Acme")
        let saved = [connection("acme-prod", groupId: acme.id), connection("scratch")]

        let sections = ConnectionSwitcherSections.build(
            active: [], saved: saved, groups: [acme], isFiltering: true
        )

        #expect(titles(sections) == ["ACTIVE CONNECTIONS", "SAVED CONNECTIONS"])
        #expect(names(sections).last == ["acme-prod", "scratch"])
    }

    @Test("A group whose connections are all open draws no rows of its own")
    func emptyGroupDrawsNothing() {
        let acme = ConnectionGroup(name: "Acme")
        let open = connection("acme-local", groupId: acme.id)

        let sections = ConnectionSwitcherSections.build(
            active: [ConnectionSwitcherEntry(id: open.id, connection: open, isActive: true, isConnected: true)],
            saved: [],
            groups: [acme],
            isFiltering: false
        )
        let rows = FieldDrivenListEntry.flatten(sections)

        #expect(rows.filter(\.isHeader).count == 1)
        #expect(rows.compactMap(\.itemId) == [open.id])
    }

    // MARK: - Moving a tab

    private func ids(_ sections: [FieldDrivenListSection<ConnectionSwitcherEntry>]) -> [UUID] {
        sections.flatMap { $0.items.map(\.id) }
    }

    private func openEntry(_ connection: DatabaseConnection) -> ConnectionSwitcherEntry {
        ConnectionSwitcherEntry(id: connection.id, connection: connection, isActive: false, isConnected: true)
    }

    @Test("A move leaves its source out of the open connections")
    func moveExcludesTheSourceFromOpen() {
        let source = connection("dev")
        let other = connection("prod")
        let active = [openEntry(source), openEntry(other)]

        let switching = ConnectionSwitcherSections.build(active: active, saved: [], groups: [], isFiltering: false)
        let moving = ConnectionSwitcherSections.build(
            active: active, saved: [], groups: [], isFiltering: false, excluding: source.id
        )

        #expect(ids(switching) == [source.id, other.id])
        #expect(ids(moving) == [other.id])
    }

    @Test("A move leaves its source out of Favorites")
    func moveExcludesTheSourceFromFavorites() {
        var source = connection("dev", sortOrder: 0)
        source.isFavorite = true
        let other = connection("prod", sortOrder: 1)

        let sections = ConnectionSwitcherSections.build(
            active: [],
            library: library([source, other], groups: [], lastConnected: [:]),
            isFiltering: false,
            excluding: source.id
        )

        #expect(!titles(sections).contains("FAVORITES"))
        #expect(ids(sections) == [other.id])
    }

    /// Dropped before Recent is capped, or a one-row Recent would show nothing at all.
    @Test("A move leaves its source out of Recent and lets the next connection take its place")
    func moveExcludesTheSourceFromRecent() {
        let source = connection("dev", sortOrder: 0)
        let older = connection("prod", sortOrder: 1)
        let request = LibraryOutlineRequest<DatabaseConnection, ConnectionGroup, ConnectionTag>(
            connections: [source, older],
            groups: [],
            tags: [],
            lastConnected: [source.id: Date(timeIntervalSince1970: 2), older.id: Date(timeIntervalSince1970: 1)],
            recentLimit: 1
        )

        let sections = ConnectionSwitcherSections.build(
            active: [], library: request, isFiltering: false, excluding: source.id
        )

        let recent = sections.first { $0.title == "RECENT" }?.items.map(\.id)
        #expect(recent == [older.id])
        #expect(!ids(sections).contains(source.id))
    }

    @Test("A move leaves its source out of its group, and a group it emptied draws no header")
    func moveExcludesTheSourceFromGroups() {
        let acme = ConnectionGroup(name: "Acme")
        let solo = ConnectionGroup(name: "Solo", sortOrder: 1)
        let source = connection("dev", groupId: solo.id)
        let sibling = connection("prod", groupId: acme.id)

        let sections = ConnectionSwitcherSections.build(
            active: [], saved: [source, sibling], groups: [acme, solo], isFiltering: false, excluding: source.id
        )

        #expect(titles(sections) == ["ACTIVE CONNECTIONS", "ACME"])
        #expect(ids(sections) == [sibling.id])
    }

    @Test("A move leaves its source out of the connections in no group")
    func moveExcludesTheSourceFromUngrouped() {
        let source = connection("dev", sortOrder: 0)
        let other = connection("scratch", sortOrder: 1)

        let sections = ConnectionSwitcherSections.build(
            active: [], saved: [source, other], groups: [], isFiltering: false, excluding: source.id
        )

        #expect(ids(sections) == [other.id])
    }

    @Test("A move leaves its source out of a filtered list")
    func moveExcludesTheSourceWhileFiltering() {
        let source = connection("dev")
        let other = connection("dev-replica")

        let sections = ConnectionSwitcherSections.build(
            active: [openEntry(source)], saved: [other], groups: [], isFiltering: true, excluding: source.id
        )

        #expect(titles(sections) == ["ACTIVE CONNECTIONS", "SAVED CONNECTIONS"])
        #expect(ids(sections) == [other.id])
    }

    @Test("The row order the arrow keys walk is the order the sections draw")
    func rowOrderFollowsTheSections() {
        let acme = ConnectionGroup(name: "Acme")
        let open = connection("acme-local", groupId: acme.id)
        let saved = [connection("acme-prod", groupId: acme.id), connection("scratch")]

        let sections = ConnectionSwitcherSections.build(
            active: [ConnectionSwitcherEntry(id: open.id, connection: open, isActive: true, isConnected: true)],
            saved: saved,
            groups: [acme],
            isFiltering: false
        )

        #expect(
            FieldDrivenListEntry.flatten(sections).compactMap(\.itemId)
                == [open.id, saved[0].id, saved[1].id]
        )
    }
}
