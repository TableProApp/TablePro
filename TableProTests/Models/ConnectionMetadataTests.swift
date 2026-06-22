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
