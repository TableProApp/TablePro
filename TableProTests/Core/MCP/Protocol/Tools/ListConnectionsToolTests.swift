//
//  ListConnectionsToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

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

    private func callForDisplay(
        scopes: Set<MCPScope>,
        settingOn: Bool,
        principal: MCPPrincipal? = nil
    ) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: .object(["purpose": .string("display")]),
            context: MCPToolTestHarness.context(
                principal: principal ?? MCPToolTestHarness.principal(scopes: scopes)
            ),
            services: MCPToolTestHarness.services(
                settings: MCPSettings(allowsHiddenConnectionListing: settingOn)
            )
        )
    }

    private func expectDisplayRefused(
        scopes: Set<MCPScope>,
        settingOn: Bool,
        principal: MCPPrincipal? = nil
    ) async {
        do {
            _ = try await callForDisplay(scopes: scopes, settingOn: settingOn, principal: principal)
            Issue.record("Expected purpose display to be refused")
        } catch let error as MCPProtocolError {
            let required = error.data?["requiredScopes"]?.arrayValue?.compactMap { $0.stringValue }
            #expect(error.code == JsonRpcErrorCode.forbidden)
            #expect(required == ["connections:display"])
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("Tool exposes read-only metadata and takes only an optional purpose")
    func metadata() {
        #expect(ListConnectionsTool.name == "list_connections")
        #expect(ListConnectionsTool.requiredScopes == [.toolsRead])
        #expect(ListConnectionsTool.annotations.readOnlyHint == true)
        let schema = ListConnectionsTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        #expect(schema["properties"]?.objectValue?.keys.sorted() == ["purpose"])
        #expect(schema["properties"]?["purpose"]?["enum"] == .array([.string("agent"), .string("display")]))
        #expect(schema["required"] == nil)
        #expect(schema["additionalProperties"]?.boolValue == false)
    }

    @Test("The output schema declares the user name and never a password")
    func outputSchemaHasNoPassword() throws {
        let output = try #require(ListConnectionsTool.outputSchema)
        let entry = try #require(output["properties"]?["connections"]?["items"])
        let fields = try #require(entry["properties"]?.objectValue)
        let required = Set(entry["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(fields["username"] != nil)
        #expect(!required.contains("username"))
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

    @Test("The agent listing never carries a user name")
    func agentListingHasNoUsername() async throws {
        for arguments: JsonValue in [.object([:]), .object(["purpose": .string("agent")])] {
            let result = try await tool.call(
                arguments: arguments,
                context: MCPToolTestHarness.context(
                    principal: MCPToolTestHarness.principal(scopes: [.toolsRead, .connectionsDisplay])
                ),
                services: MCPToolTestHarness.services(settings: MCPSettings(allowsHiddenConnectionListing: true))
            )
            let connections = try #require(result.structuredContent?["connections"]?.arrayValue)
            for entry in connections {
                #expect(entry["username"] == nil)
            }
        }
    }

    @Test("purpose display without the scope is refused with the scope it needs")
    func displayWithoutScopeIsRefused() async {
        await expectDisplayRefused(scopes: [.toolsRead, .toolsWrite, .resourcesRead], settingOn: true)
        await expectDisplayRefused(scopes: MCPScope.fullAccessSet, settingOn: true)
    }

    @Test("purpose display is refused while the setting is off, even for a token holding the scope")
    func displayRefusedWhileSettingIsOff() async {
        await expectDisplayRefused(scopes: [.toolsRead, .connectionsDisplay], settingOn: false)
    }

    @Test("An anonymous caller never gets purpose display")
    func anonymousNeverGetsDisplay() async {
        let anonymous = MCPPrincipal(
            tokenFingerprint: MCPPrincipal.anonymousFingerprint,
            tokenId: nil,
            scopes: [.toolsRead, .connectionsDisplay],
            metadata: MCPPrincipal.anonymousLoopback.metadata
        )
        await expectDisplayRefused(scopes: [], settingOn: true, principal: anonymous)
    }

    @Test("With the scope and the setting on, purpose display lists display fields only")
    func displayWithScopeAndSetting() async throws {
        let result = try await callForDisplay(scopes: [.toolsRead, .connectionsDisplay], settingOn: true)
        #expect(!result.isError)
        let connections = try #require(result.structuredContent?["connections"]?.arrayValue)
        let allowed: Set<String> = [
            "id", "name", "type", "host", "port", "database", "is_connected",
            "color", "group", "tags", "username"
        ]
        for entry in connections {
            let fields = try #require(entry.objectValue)
            #expect(Set(fields.keys).isSubset(of: allowed), "unexpected field in \(fields.keys.sorted())")
            #expect(fields["username"]?.stringValue != nil)
        }
    }

    @Test("A purpose outside the enum is an error, not a silent fallback")
    func unknownPurposeIsAnError() async throws {
        let result = try await tool.call(
            arguments: .object(["purpose": .string("everything")]),
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
        #expect(result.isError)
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
            "is_connected", "ai_policy", "external_access", "safe_mode",
            "color", "group", "tags"
        ]
        for entry in connections {
            let fields = try #require(entry.objectValue)
            #expect(Set(fields.keys).isSubset(of: allowed), "unexpected field in \(fields.keys.sorted())")
            #expect(fields["id"]?.stringValue != nil)
            #expect(fields["tags"]?.arrayValue != nil)
        }
    }

    @Test("The output schema declares color, group and tags, and requires tags")
    func outputSchemaDeclaresLabels() throws {
        let output = try #require(ListConnectionsTool.outputSchema)
        let entry = try #require(output["properties"]?["connections"]?["items"])
        let fields = try #require(entry["properties"]?.objectValue)
        let required = Set(entry["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])

        let colors: [JsonValue] = ["red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"].map { .string($0) }
        #expect(fields["color"]?["enum"] == .array(colors))
        #expect(fields["group"]?["type"]?.stringValue == "object")
        #expect(fields["group"]?["properties"]?["path"]?["type"]?.stringValue == "array")
        #expect(fields["group"]?["properties"]?["color"]?["enum"] == .array(colors))
        #expect(fields["tags"]?["type"]?.stringValue == "array")
        #expect(fields["tags"]?["items"]?["properties"]?["name"] != nil)
        #expect(fields["tags"]?["items"]?["properties"]?["color"]?["enum"] == .array(colors))
        #expect(required.contains("tags"))
        #expect(!required.contains("color"))
        #expect(!required.contains("group"))
    }
}
