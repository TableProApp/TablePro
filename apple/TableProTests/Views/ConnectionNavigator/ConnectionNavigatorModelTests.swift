//
//  ConnectionNavigatorModelTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProTestSupport
import Testing

@MainActor
struct ConnectionNavigatorModelTests {
    private let fixture: ConnectionNavigatorFixture

    init() throws {
        fixture = try ConnectionNavigatorFixture()
    }

    private static func connectionRow(_ id: UUID, in rows: [ConnectionNavigatorRow]) -> ConnectionNavigatorConnectionRow? {
        for row in rows {
            switch row {
            case .connection(let connection) where connection.id == id:
                return connection
            case .connection:
                continue
            case .group(let group):
                if let nested = connectionRow(id, in: group.children) { return nested }
            }
        }
        return nil
    }

    @Test("A connection saved elsewhere appears once the library says it changed")
    func rebuildsOnConnectionUpdated() async throws {
        let model = fixture.makeModel()
        model.start()
        defer { model.stop() }
        let before = model.revision

        fixture.save([TestFixtures.makeConnection(name: "Orders")])
        fixture.events.connectionUpdated.send(nil)

        try await waitUntil { model.rows.count == 1 }
        #expect(model.revision > before)
    }

    @Test("A status change repaints the status without a rebuild")
    func statusChangeRepaintsOnly() async throws {
        let connection = TestFixtures.makeConnection(name: "Orders")
        fixture.save([connection])
        let model = fixture.makeModel()
        model.start()
        defer { model.stop() }
        let revision = model.revision
        let presentation = model.presentationRevision

        fixture.statuses[connection.id] = .connecting
        fixture.events.connectionPhaseChanged.send(connection.id)

        try await waitUntil { Self.connectionRow(connection.id, in: model.rows)?.status == .connecting }
        #expect(model.revision == revision)
        #expect(model.presentationRevision > presentation)
    }

    @Test("The shown connection, one hosted here and one open in another window are told apart")
    func marksShownOpenHereAndElsewhere() throws {
        let shown = TestFixtures.makeConnection(name: "Shown")
        let hosted = TestFixtures.makeConnection(name: "Hosted")
        let elsewhere = TestFixtures.makeConnection(name: "Elsewhere")
        let closed = TestFixtures.makeConnection(name: "Closed")
        fixture.save([shown, hosted, elsewhere, closed])
        fixture.host.hosted = [shown.id, hosted.id]
        fixture.host.selected = shown.id
        fixture.hostedAnywhere = [elsewhere.id]
        let model = fixture.makeModel()
        model.start()
        defer { model.stop() }

        #expect(try #require(Self.connectionRow(shown.id, in: model.rows)).placement == .shownHere)
        #expect(try #require(Self.connectionRow(hosted.id, in: model.rows)).placement == .openHere)
        #expect(try #require(Self.connectionRow(elsewhere.id, in: model.rows)).placement == .openElsewhere)
        #expect(try #require(Self.connectionRow(closed.id, in: model.rows)).placement == .notOpen)
    }

    @Test("Expanding a group is remembered, but not while a filter opens groups for the user")
    func expansionPersistsAndIgnoresFilter() throws {
        let kept = ConnectionGroup(name: "Kept")
        let filtered = ConnectionGroup(name: "Filtered")
        try fixture.groupStorage.addGroup(kept)
        try fixture.groupStorage.addGroup(filtered)
        let model = fixture.makeModel()
        model.start()
        defer { model.stop() }

        model.setGroupExpanded(kept.id, true)
        #expect(fixture.expansionStore.load(keeping: [kept.id, filtered.id]) == [kept.id])

        model.filterText = "x"
        model.setGroupExpanded(filtered.id, true)
        #expect(fixture.expansionStore.load(keeping: [kept.id, filtered.id]) == [kept.id])
    }

    @Test("A group made from the navigator opens, and so does its parent")
    func createdGroupOpensWithItsParent() throws {
        let parent = ConnectionGroup(name: "Parent")
        try fixture.groupStorage.addGroup(parent)
        let model = fixture.makeModel()
        model.start()
        defer { model.stop() }

        try model.createGroup(ConnectionGroupFields(name: "Child", parentId: parent.id))

        let child = try #require(fixture.groupStorage.loadGroups().first { $0.name == "Child" })
        #expect(fixture.expansionStore.load(keeping: [parent.id, child.id]) == [parent.id, child.id])
    }

    @Test("The library reads empty until it holds a connection")
    func libraryEmptyTracksConnections() {
        let model = fixture.makeModel()
        model.start()
        defer { model.stop() }
        #expect(model.isLibraryEmpty)

        fixture.save([TestFixtures.makeConnection(name: "Orders")])
        model.rebuild()

        #expect(!model.isLibraryEmpty)
    }
}
