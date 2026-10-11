//
//  ExternalConnectionDirectoryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ExternalConnectionDirectoryTests {
    private func listings(
        _ connections: [DatabaseConnection],
        groups: [ConnectionGroup] = [],
        tags: [ConnectionTag] = [],
        live: [UUID: ExternalConnectionDirectory.LiveState] = [:],
        defaultPolicy: AIConnectionPolicy = .askEachTime
    ) -> [ExternalConnectionListing] {
        ExternalConnectionDirectory.listings(
            connections: connections,
            groups: groups,
            tags: tags,
            live: live,
            defaultPolicy: defaultPolicy
        )
    }

    @Test("A Blocked connection is not listed, every other level is")
    func blockedIsDropped() {
        let readOnly = DatabaseConnection(name: "A", externalAccess: .readOnly)
        let readWrite = DatabaseConnection(name: "B", externalAccess: .readWrite)
        let blocked = DatabaseConnection(name: "C", externalAccess: .blocked)

        let result = listings([blocked, readWrite, readOnly])

        #expect(result.map(\.id) == [readOnly.id, readWrite.id])
        #expect(result.map(\.externalAccess) == [.readOnly, .readWrite])
    }

    @Test("A nested group carries its path from the top-level group down")
    func nestedGroupPath() throws {
        let root = ConnectionGroup(name: "Clients", color: .blue)
        let child = ConnectionGroup(name: "Acme", color: .red, parentId: root.id)
        let connection = DatabaseConnection(name: "Acme prod", groupId: child.id)

        let listing = try #require(listings([connection], groups: [root, child]).first)

        #expect(listing.group == ExternalConnectionListing.Group(
            id: child.id, name: "Acme", path: ["Clients", "Acme"], color: .red
        ))
    }

    @Test("A connection in a top-level group has a one-name path")
    func topLevelGroupPath() throws {
        let group = ConnectionGroup(name: "Local")
        let connection = DatabaseConnection(name: "Dev", groupId: group.id)

        let listing = try #require(listings([connection], groups: [group]).first)

        #expect(listing.group?.path == ["Local"])
        #expect(listing.group?.color == ConnectionColor.none)
    }

    @Test("No group, or a group that no longer exists, gives no group")
    func missingGroup() {
        let ungrouped = DatabaseConnection(name: "A")
        let orphaned = DatabaseConnection(name: "B", groupId: UUID())

        let result = listings([ungrouped, orphaned], groups: [ConnectionGroup(name: "Other")])

        #expect(result.allSatisfy { $0.group == nil })
    }

    @Test("A parent cycle in stored groups still ends the path")
    func groupCycleEndsThePath() throws {
        let firstId = UUID()
        let secondId = UUID()
        let first = ConnectionGroup(id: firstId, name: "First", parentId: secondId)
        let second = ConnectionGroup(id: secondId, name: "Second", parentId: firstId)
        let connection = DatabaseConnection(name: "A", groupId: firstId)

        let listing = try #require(listings([connection], groups: [first, second]).first)

        #expect(listing.group?.path == ["First"])
    }

    @Test("Tags follow the connection's order, skipping unknown and repeated ids")
    func tagOrder() throws {
        let production = ConnectionTag(name: "production", color: .red)
        let reporting = ConnectionTag(name: "reporting", color: .none)
        let connection = DatabaseConnection(
            name: "A",
            tagIds: [reporting.id, UUID(), production.id, reporting.id]
        )

        let listing = try #require(listings([connection], tags: [production, reporting]).first)

        #expect(listing.tags == [
            ExternalConnectionListing.Tag(id: reporting.id, name: "reporting", color: .none),
            ExternalConnectionListing.Tag(id: production.id, name: "production", color: .red)
        ])
    }

    @Test("A connection with no tags lists none")
    func noTags() throws {
        let listing = try #require(listings([DatabaseConnection(name: "A")], tags: ConnectionTag.presets).first)
        #expect(listing.tags.isEmpty)
    }

    @Test("A connection with no AI policy of its own takes the app default")
    func aiPolicyDefault() {
        let inherits = DatabaseConnection(name: "A")
        let own = DatabaseConnection(name: "B", aiPolicy: .alwaysAllow)

        let result = listings([inherits, own], defaultPolicy: .never)

        #expect(result.map(\.aiPolicy) == [.never, .alwaysAllow])
    }

    @Test("A live session supplies the browsed database, schema and connected state")
    func liveSession() throws {
        let connection = DatabaseConnection(name: "A", database: "saved")
        let live = ExternalConnectionDirectory.LiveState(database: "analytics", schema: "reporting", isConnected: true)

        let listing = try #require(listings([connection], live: [connection.id: live]).first)

        #expect(listing.database == "analytics")
        #expect(listing.schema == "reporting")
        #expect(listing.isConnected)
    }

    @Test("Without a session the saved database is listed and nothing is connected")
    func noSession() throws {
        let connection = DatabaseConnection(name: "A", database: "saved")

        let listing = try #require(listings([connection]).first)

        #expect(listing.database == "saved")
        #expect(listing.schema == nil)
        #expect(!listing.isConnected)
    }

    @Test("Saved fields pass through unchanged")
    func savedFields() throws {
        let connection = DatabaseConnection(
            name: "Acme",
            host: "db.acme.io",
            port: 5_432,
            type: .postgresql,
            color: .orange,
            safeModeLevel: .alert,
            externalAccess: .readWrite
        )

        let listing = try #require(listings([connection]).first)

        #expect(listing.id == connection.id)
        #expect(listing.name == "Acme")
        #expect(listing.databaseType == DatabaseType.postgresql.rawValue)
        #expect(listing.host == "db.acme.io")
        #expect(listing.port == 5_432)
        #expect(listing.color == .orange)
        #expect(listing.safeModeLevel == connection.safeModeLevel)
        #expect(listing.externalAccess == .readWrite)
    }

    @Test("Listings sort by name as Finder does, then by id")
    func sortOrder() throws {
        let lowId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let connections = [
            DatabaseConnection(name: "db10"),
            DatabaseConnection(id: highId, name: "Same"),
            DatabaseConnection(name: "db2"),
            DatabaseConnection(id: lowId, name: "Same"),
            DatabaseConnection(name: "alpha")
        ]

        let result = listings(connections)

        #expect(result.map(\.name) == ["alpha", "db2", "db10", "Same", "Same"])
        #expect(result.suffix(2).map(\.id) == [lowId, highId])
    }

    @Test("Every color has a fixed lowercase name, and none has no name")
    func externalColorNames() {
        #expect(ConnectionColor.none.externalName == nil)
        let named = ConnectionColor.allCases.filter { $0 != .none }.compactMap(\.externalName)
        #expect(named == ["red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"])
    }
}
