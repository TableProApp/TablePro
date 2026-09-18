//
//  ListConnectionsToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ListConnectionsTool")
struct ListConnectionsToolTests {
    private let tool = ListConnectionsTool()

    private func call(access: ConnectionAccess) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: .object([:]),
            context: MCPToolTestHarness.context(
                principal: MCPToolTestHarness.principal(access: access)
            ),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Tool exposes read-only metadata and takes no arguments")
    func metadata() {
        #expect(ListConnectionsTool.name == "list_connections")
        #expect(ListConnectionsTool.requiredScopes == [.toolsRead])
        #expect(ListConnectionsTool.annotations.readOnlyHint == true)
        let schema = ListConnectionsTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        #expect(schema["properties"] == nil)
        #expect(schema["additionalProperties"]?.boolValue == false)
    }

    @Test("The listing never carries a username")
    func listingNeverCarriesAUsername() throws {
        let output = try #require(ListConnectionsTool.outputSchema)
        let entry = try #require(output["properties"]?["connections"]?["items"])
        let fields = try #require(entry["properties"]?.objectValue)
        #expect(fields["username"] == nil)
        #expect(fields["password"] == nil)
        #expect(fields["id"] != nil)
        #expect(fields["host"] != nil)
        #expect(fields["port"] != nil)
        #expect(fields["database"] != nil)
    }

    @Test("Any argument at all is rejected rather than ignored")
    func argumentsAreRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object(["connection_id": .string(UUID().uuidString)]),
                context: MCPToolTestHarness.context(),
                services: MCPToolTestHarness.services()
            )
        }
    }

    @Test("A token with no connection grant learns nothing about any connection")
    func emptyGrantLearnsNothing() async throws {
        let result = try await call(access: .limited([]))
        #expect(!result.isError)
        let connections = try #require(result.structuredContent?["connections"]?.arrayValue)
        #expect(connections.isEmpty)
    }

    @Test("A token granted only an unknown connection still learns nothing")
    func grantForAnUnsavedConnectionLearnsNothing() async throws {
        let result = try await call(access: .limited([UUID()]))
        let connections = try #require(result.structuredContent?["connections"]?.arrayValue)
        #expect(connections.isEmpty)
    }

    @Test("The bridge applies the same grant when asked directly")
    func bridgeAppliesTheGrant() async throws {
        let bridge = MCPConnectionBridge()
        let payload = await bridge.listConnections(
            principal: MCPToolTestHarness.principal(access: .limited([]))
        )
        #expect(payload["connections"]?.arrayValue?.isEmpty == true)
    }

    @Test("Every entry the listing does return carries the documented fields and no more")
    func entriesCarryOnlyTheDocumentedFields() async throws {
        let result = try await call(access: .all)
        let connections = try #require(result.structuredContent?["connections"]?.arrayValue)
        let allowed: Set<String> = [
            "id", "name", "type", "host", "port", "database",
            "is_connected", "ai_policy", "external_access", "safe_mode"
        ]
        for entry in connections {
            let fields = try #require(entry.objectValue)
            #expect(Set(fields.keys).isSubset(of: allowed), "unexpected field in \(fields.keys.sorted())")
            #expect(fields["id"]?.stringValue != nil)
        }
    }
}
