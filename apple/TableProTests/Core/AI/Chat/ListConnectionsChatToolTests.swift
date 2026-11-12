//
//  ListConnectionsChatToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

struct ListConnectionsChatToolTests {
    private let session = UUID()
    private let other = UUID()
    private let third = UUID()

    private func context(
        connectionId: UUID?,
        policy: AIConnectionPolicy = .askEachTime
    ) -> ChatToolContext {
        ChatToolContext(
            connectionId: connectionId,
            bridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(),
            policyLookup: { _ in policy }
        )
    }

    private func connection(id: UUID, name: String, host: String) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection(id: id, name: name, database: "\(name)_db", type: .postgresql)
        connection.host = host
        return connection
    }

    @Test("A conversation with no connection attached lists nothing")
    func noSessionConnectionIsRefused() async {
        await #expect(throws: ChatToolTargetError.noConnection) {
            _ = try await ListConnectionsChatTool().execute(input: .object([:]), context: context(connectionId: nil))
        }
    }

    @Test("A connection whose AI policy is Never is refused")
    func neverPolicyIsRefused() async {
        await #expect(throws: ChatToolAuthorizationError.self) {
            _ = try await ListConnectionsChatTool().execute(
                input: .object([:]),
                context: context(connectionId: session, policy: .never)
            )
        }
    }

    @Test("The tool lists no connection other than the conversation's own")
    func toolListsOnlyTheSessionConnection() async throws {
        let result = try await ListConnectionsChatTool().execute(
            input: .object([:]),
            context: context(connectionId: session)
        )
        let data = try #require(result.content.data(using: .utf8))
        let payload = try JSONDecoder().decode(JsonValue.self, from: data)
        let listed = try #require(payload["connections"]?.arrayValue)

        for entry in listed {
            #expect(entry["id"]?.stringValue == session.uuidString)
        }
    }

    @Test("The listing carries the session's connection and no other host or name")
    func listingHoldsOnlyTheSessionEntry() throws {
        let listings = ExternalConnectionDirectory.listings(
            connections: [
                connection(id: session, name: "dev", host: "localhost"),
                connection(id: other, name: "prod_payments", host: "db1.internal.corp"),
                connection(id: third, name: "ledger", host: "10.0.0.5")
            ],
            groups: [],
            tags: [],
            live: [:],
            defaultPolicy: .askEachTime
        )

        let payload = MCPConnectionBridge.connectionListing(listings, id: session)
        let listed = try #require(payload["connections"]?.arrayValue)
        let text = payload.jsonString()

        #expect(listed.count == 1)
        #expect(listed.first?["id"]?.stringValue == session.uuidString)
        #expect(!text.contains("prod_payments"))
        #expect(!text.contains("db1.internal.corp"))
        #expect(!text.contains("ledger"))
        #expect(!text.contains("10.0.0.5"))
    }

    @Test("The tool's description no longer promises every saved connection")
    func descriptionNamesTheSessionConnection() {
        #expect(!ListConnectionsChatTool().description.localizedCaseInsensitiveContains("all saved"))
    }
}
