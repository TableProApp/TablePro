//
//  MCPWorkspaceToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Workspace listings honour the connection grant")
struct MCPWorkspaceToolTests {
    private let granted = UUID()
    private let withheld = UUID()

    private func services(withheldPolicy: AIConnectionPolicy = .alwaysAllow) -> MCPToolServices {
        MCPToolTestHarness.services(
            authPolicy: MCPToolTestHarness.authPolicy(connections: [
                granted: MCPToolTestHarness.snapshot(name: "Granted"),
                withheld: MCPToolTestHarness.snapshot(policy: withheldPolicy, name: "Withheld")
            ])
        )
    }

    private func call(
        _ tool: any MCPToolImplementation,
        connectionId: UUID,
        access: ConnectionAccess,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: .object(["connection_id": .string(connectionId.uuidString)]),
            context: MCPToolTestHarness.context(
                principal: MCPToolTestHarness.principal(access: access)
            ),
            services: services
        )
    }

    @Test("Both listings are read-only and take only a connection")
    func metadata() {
        #expect(ListFavoriteTablesTool.name == "list_favorite_tables")
        #expect(ListRecentTablesTool.name == "list_recent_tables")
        #expect(ListFavoriteTablesTool.requiredScopes == [.toolsRead])
        #expect(ListRecentTablesTool.requiredScopes == [.toolsRead])
        #expect(ListFavoriteTablesTool.annotations.readOnlyHint == true)
        #expect(ListRecentTablesTool.annotations.readOnlyHint == true)
        #expect(
            ListFavoriteTablesTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
                == ["connection_id"]
        )
    }

    @Test("A token limited to one connection cannot read another one's favorites")
    func favoritesHonourTheGrant() async throws {
        let result = try await call(
            ListFavoriteTablesTool(),
            connectionId: withheld,
            access: .limited([granted]),
            services: services()
        )
        #expect(result.isError)
        let text = MCPToolTestHarness.errorText(result) ?? ""
        #expect(text.hasPrefix("denied:"))
        #expect(!text.contains("Withheld"))
    }

    @Test("A token limited to one connection cannot read another one's recent tables")
    func recentTablesHonourTheGrant() async throws {
        let result = try await call(
            ListRecentTablesTool(),
            connectionId: withheld,
            access: .limited([granted]),
            services: services()
        )
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("denied:") == true)
    }

    @Test("A connection the user set to never share with AI is unreachable from both listings")
    func aiPolicyNeverIsUnreachable() async throws {
        let blocked = services(withheldPolicy: .never)
        for tool in [ListFavoriteTablesTool() as any MCPToolImplementation, ListRecentTablesTool()] {
            let result = try await call(
                tool,
                connectionId: withheld,
                access: .all,
                services: blocked
            )
            #expect(result.isError, "\(type(of: tool).name) must refuse a never-share connection")
        }
    }

    @Test("A granted connection returns an empty listing rather than a refusal")
    func grantedConnectionReturnsAListing() async throws {
        let favorites = try await call(
            ListFavoriteTablesTool(),
            connectionId: granted,
            access: .limited([granted]),
            services: services()
        )
        #expect(!favorites.isError)
        #expect(favorites.structuredContent?["favorites"]?.arrayValue != nil)

        let recents = try await call(
            ListRecentTablesTool(),
            connectionId: granted,
            access: .limited([granted]),
            services: services()
        )
        #expect(!recents.isError)
        #expect(recents.structuredContent?["recent_tables"]?.arrayValue != nil)
    }

    @Test("An unknown parameter is rejected by both listings")
    func unknownParametersAreRejected() async throws {
        for tool in [ListFavoriteTablesTool() as any MCPToolImplementation, ListRecentTablesTool()] {
            await #expect(throws: MCPProtocolError.self) {
                _ = try await tool.call(
                    arguments: .object([
                        "connection_id": .string(granted.uuidString),
                        "database": .string("shop")
                    ]),
                    context: MCPToolTestHarness.context(),
                    services: services()
                )
            }
        }
    }
}
