//
//  ListRecentTabsToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ListRecentTabsTool")
struct ListRecentTabsToolTests {
    private let tool = ListRecentTabsTool()
    private let granted = UUID()
    private let withheld = UUID()

    private func services(
        grantedPolicy: AIConnectionPolicy = .alwaysAllow,
        grantedAccess: ExternalAccessLevel = .readWrite,
        withheldPolicy: AIConnectionPolicy = .alwaysAllow,
        withheldAccess: ExternalAccessLevel = .readWrite
    ) -> MCPToolServices {
        MCPToolTestHarness.services(
            authPolicy: MCPToolTestHarness.authPolicy(connections: [
                granted: MCPToolTestHarness.snapshot(
                    policy: grantedPolicy,
                    externalAccess: grantedAccess,
                    name: "Granted"
                ),
                withheld: MCPToolTestHarness.snapshot(
                    policy: withheldPolicy,
                    externalAccess: withheldAccess,
                    name: "Withheld"
                )
            ])
        )
    }

    private func call(
        _ arguments: JsonValue,
        access: ConnectionAccess,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(
                principal: MCPToolTestHarness.principal(access: access)
            ),
            services: services
        )
    }

    @Test("Tool exposes read-only metadata and a bounded limit")
    func metadata() {
        #expect(ListRecentTabsTool.name == "list_recent_tabs")
        #expect(ListRecentTabsTool.requiredScopes == [.toolsRead])
        #expect(ListRecentTabsTool.annotations.readOnlyHint == true)
        let schema = ListRecentTabsTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        #expect(schema["required"] == nil)
        #expect(schema["properties"]?["limit"]?["minimum"]?.intValue == 1)
        #expect(schema["properties"]?["limit"]?["maximum"]?.intValue == 500)
    }

    @Test("With no arguments the listing succeeds and returns a tabs array")
    func emptyArgumentsSucceed() async throws {
        let result = try await call(.object([:]), access: .all, services: services())
        #expect(!result.isError)
        #expect(result.structuredContent?["tabs"]?.arrayValue != nil)
        #expect(result.structuredContent?.objectValue?.keys.sorted() == ["tabs"])
    }

    @Test("A token limited to one connection cannot name another one")
    func limitedTokenCannotNameAnotherConnection() async throws {
        let result = try await call(
            .object(["connection_id": .string(withheld.uuidString)]),
            access: .limited([granted]),
            services: services()
        )
        #expect(result.isError)
        let text = MCPToolTestHarness.errorText(result) ?? ""
        #expect(text.hasPrefix("denied:"))
        #expect(!text.contains("Withheld"), "the refusal must not reveal the connection's name")
        #expect(!text.contains(withheld.uuidString))
    }

    @Test("A connection the user set to never share with AI is not reachable")
    func aiPolicyNeverIsNotReachable() async throws {
        let result = try await call(
            .object(["connection_id": .string(withheld.uuidString)]),
            access: .all,
            services: services(withheldPolicy: .never)
        )
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("denied:") == true)
    }

    @Test("A connection blocked for external clients is not reachable")
    func blockedExternalAccessIsNotReachable() async throws {
        let result = try await call(
            .object(["connection_id": .string(withheld.uuidString)]),
            access: .all,
            services: services(withheldAccess: .blocked)
        )
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("denied:") == true)
    }

    @Test("A connection inside the grant is accepted")
    func grantedConnectionIsAccepted() async throws {
        let result = try await call(
            .object(["connection_id": .string(granted.uuidString)]),
            access: .limited([granted]),
            services: services()
        )
        #expect(!result.isError)
        #expect(result.structuredContent?["tabs"]?.arrayValue?.isEmpty == true)
    }

    @Test("A limit outside the documented range is reported, not clamped")
    func limitOutsideRangeIsReported() async throws {
        for limit in [0, 501, -1] {
            let result = try await call(
                .object(["limit": .int(limit)]),
                access: .all,
                services: services()
            )
            #expect(result.isError, "limit \(limit) must be reported")
            #expect(MCPToolTestHarness.errorText(result)?.contains("limit") == true)
        }
    }

    @Test("A wrongly typed limit is a protocol error")
    func wronglyTypedLimitIsAProtocolError() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(
                .object(["limit": .string("20")]),
                access: .all,
                services: services()
            )
        }
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(
                .object(["window_id": .string(UUID().uuidString)]),
                access: .all,
                services: services()
            )
        }
    }
}
