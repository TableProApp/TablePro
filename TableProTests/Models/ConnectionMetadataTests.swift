//
//  ConnectionMetadataTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("ConnectionMetadata")
struct ConnectionMetadataTests {
    private func makeConnection(tagIds: [UUID] = [], groupId: UUID? = nil) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Test")
        connection.tagIds = tagIds
        connection.groupId = groupId
        return connection
    }

    private let production = ConnectionTag(name: "production", color: .red)
    private let staging = ConnectionTag(name: "staging", color: .orange)
    private let group = ConnectionGroup(id: UUID(), name: "Backend", sortOrder: 0)

    @Test("Resolves assigned tags in order and the assigned group")
    func resolvesAssigned() {
        let connection = makeConnection(tagIds: [staging.id, production.id], groupId: group.id)

        let result = ConnectionMetadata.resolve(
            connection: connection,
            tags: [production, staging],
            groups: [group]
        )

        #expect(result.tags == [staging, production])
        #expect(result.group == group)
    }

    @Test("Returns no tags and no group when nothing is assigned")
    func returnsEmptyWhenUnassigned() {
        let connection = makeConnection()

        let result = ConnectionMetadata.resolve(
            connection: connection,
            tags: [production],
            groups: [group]
        )

        #expect(result.tags.isEmpty)
        #expect(result.group == nil)
    }

    @Test("Drops tag and group references that no longer exist")
    func dropsStaleReferences() {
        let connection = makeConnection(tagIds: [production.id, UUID()], groupId: UUID())

        let result = ConnectionMetadata.resolve(
            connection: connection,
            tags: [production],
            groups: [group]
        )

        #expect(result.tags == [production])
        #expect(result.group == nil)
    }
}

@Suite("ConnectionTagsBadgeLayout")
struct ConnectionTagsBadgeLayoutTests {
    private func tags(_ count: Int) -> [ConnectionTag] {
        (0 ..< count).map { ConnectionTag(name: "tag\($0)") }
    }

    @Test("Empty input shows nothing")
    func empty() {
        let layout = ConnectionTagsBadgeLayout(tags: [])

        #expect(layout.shown.isEmpty)
        #expect(layout.overflow == 0)
        #expect(layout.name == nil)
    }

    @Test("A single tag shows its name and no overflow")
    func single() {
        let tag = ConnectionTag(name: "production")
        let layout = ConnectionTagsBadgeLayout(tags: [tag])

        #expect(layout.shown == [tag])
        #expect(layout.overflow == 0)
        #expect(layout.name == "production")
    }

    @Test("Up to three tags show dots only, no name and no overflow")
    func threeShowDotsOnly() {
        let layout = ConnectionTagsBadgeLayout(tags: tags(3))

        #expect(layout.shown.count == 3)
        #expect(layout.overflow == 0)
        #expect(layout.name == nil)
    }

    @Test("More than three tags cap at three dots and report the overflow count")
    func overflow() {
        let layout = ConnectionTagsBadgeLayout(tags: tags(5))

        #expect(layout.shown.count == 3)
        #expect(layout.overflow == 2)
        #expect(layout.name == nil)
    }
}
