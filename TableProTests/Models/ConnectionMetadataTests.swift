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
    private func makeConnection(tagId: UUID? = nil, groupId: UUID? = nil) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Test")
        connection.tagId = tagId
        connection.groupId = groupId
        return connection
    }

    private let tag = ConnectionTag(name: "production", color: .red)
    private let group = ConnectionGroup(id: UUID(), name: "Backend", sortOrder: 0)

    @Test("Resolves the assigned tag and group")
    func resolvesAssigned() {
        let connection = makeConnection(tagId: tag.id, groupId: group.id)

        let result = ConnectionMetadata.resolve(connection: connection, tags: [tag], groups: [group])

        #expect(result.tag == tag)
        #expect(result.group == group)
    }

    @Test("Returns nil when no tag or group is assigned")
    func returnsNilWhenUnassigned() {
        let connection = makeConnection()

        let result = ConnectionMetadata.resolve(connection: connection, tags: [tag], groups: [group])

        #expect(result.tag == nil)
        #expect(result.group == nil)
    }

    @Test("Returns nil when the assigned tag or group no longer exists")
    func returnsNilForStaleReferences() {
        let connection = makeConnection(tagId: UUID(), groupId: UUID())

        let result = ConnectionMetadata.resolve(connection: connection, tags: [tag], groups: [group])

        #expect(result.tag == nil)
        #expect(result.group == nil)
    }
}
