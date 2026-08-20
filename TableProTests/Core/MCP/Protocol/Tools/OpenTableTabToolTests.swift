//
//  OpenTableTabToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("OpenTableTabTool")
struct OpenTableTabToolTests {
    private let tool = OpenTableTabTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Opening a tab is a write and reports both ids list_recent_tabs uses")
    func metadata() throws {
        #expect(OpenTableTabTool.name == "open_table_tab")
        #expect(OpenTableTabTool.requiredScopes == [.toolsWrite])
        #expect(OpenTableTabTool.annotations.readOnlyHint == false)
        let required = OpenTableTabTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["connection_id", "table_name"])
        let output = try #require(OpenTableTabTool.outputSchema)
        #expect(output["properties"]?["tab_id"] != nil)
        #expect(output["properties"]?["window_id"] != nil)
        let outputRequired = output["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(outputRequired.contains("tab_id"))
    }

    @Test("Missing arguments are protocol errors")
    func missingArgumentsAreProtocolErrors() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([:]))
        }
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        }
    }

    @Test("An empty table name is reported rather than opening an empty tab")
    func emptyTableNameIsReported() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "table_name": .string("   ")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("An unknown connection is refused before any window opens")
    func unknownConnectionOpensNothing() async throws {
        let unknownId = UUID()
        let result = try await call(.object([
            "connection_id": .string(unknownId.uuidString),
            "table_name": .string("users")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_found:") == true)
        let snapshots = await MainActor.run { MCPTabSnapshotProvider.collectTabSnapshots() }
        #expect(snapshots.contains { $0.connectionId == unknownId } == false)
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "table_name": .string("users"),
                "window_id": .string(UUID().uuidString)
            ]))
        }
    }
}

@Suite("OpenConnectionWindowTool")
struct OpenConnectionWindowToolTests {
    private let tool = OpenConnectionWindowTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Opening a window is a write and reports the same window id list_recent_tabs uses")
    func metadata() throws {
        #expect(OpenConnectionWindowTool.name == "open_connection_window")
        #expect(OpenConnectionWindowTool.requiredScopes == [.toolsWrite])
        let required = OpenConnectionWindowTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["connection_id"])
        let output = try #require(OpenConnectionWindowTool.outputSchema)
        #expect(output["properties"]?["window_id"] != nil)
        #expect(output["properties"]?["tab_id"] != nil)
        #expect(output["properties"]?["is_connected"] != nil)
    }

    @Test("Missing connection_id is a protocol error")
    func missingConnectionId() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([:]))
        }
    }

    @Test("A malformed connection id is a tool error")
    func malformedConnectionId() async throws {
        let result = try await call(.object(["connection_id": .string("not-a-uuid")]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("An unknown connection is refused before any window opens")
    func unknownConnectionOpensNothing() async throws {
        let unknownId = UUID()
        let result = try await call(.object(["connection_id": .string(unknownId.uuidString)]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_found:") == true)
        let snapshots = await MainActor.run { MCPTabSnapshotProvider.collectTabSnapshots() }
        #expect(snapshots.contains { $0.connectionId == unknownId } == false)
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "table_name": .string("users")
            ]))
        }
    }
}
