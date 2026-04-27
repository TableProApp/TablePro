//
//  MCPToolHandlerIntegrationTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("MCP Tool Handler — integration tools", .serialized)
@MainActor
struct MCPToolHandlerIntegrationTests {
    private let storage = ConnectionStorage.shared

    private func makeHandler() -> MCPToolHandler {
        MCPToolHandler(bridge: MCPConnectionBridge(), authGuard: MCPAuthGuard())
    }

    private func makeToken(
        permissions: TokenPermissions = .readWrite,
        allowedConnectionIds: Set<UUID>? = nil
    ) -> MCPAuthToken {
        MCPAuthToken(
            id: UUID(),
            name: "test-token",
            prefix: "tp_test1",
            tokenHash: "fakehash",
            salt: "fakesalt",
            permissions: permissions,
            allowedConnectionIds: allowedConnectionIds,
            createdAt: Date.now,
            lastUsedAt: nil,
            expiresAt: nil,
            isActive: true
        )
    }

    private func withConnections(
        _ connections: [DatabaseConnection],
        body: () async throws -> Void
    ) async throws {
        let original = storage.loadConnections()
        defer { storage.saveConnections(original) }
        storage.saveConnections(connections)
        try await body()
    }

    // MARK: - list_connections

    @Test("list_connections omits connections with externalAccess == .blocked")
    func listConnectionsFiltersBlocked() async throws {
        let handler = makeHandler()
        let blocked = DatabaseConnection(name: "Blocked Prod", type: .mysql, externalAccess: .blocked)
        let visible = DatabaseConnection(name: "Visible Staging", type: .mysql, externalAccess: .readOnly)
        try await withConnections([blocked, visible]) {
            let result = try await handler.handleToolCall(
                name: "list_connections",
                arguments: nil,
                sessionId: "test-session",
                token: nil
            )
            #expect(result.isError == nil)
            let payload = result.content.first?.text ?? ""
            #expect(!payload.contains(blocked.id.uuidString))
            #expect(payload.contains(visible.id.uuidString))
        }
    }

    // MARK: - list_recent_tabs

    @Test("list_recent_tabs returns tabs JSON object")
    func listRecentTabsShape() async throws {
        let handler = makeHandler()
        let result = try await handler.handleToolCall(
            name: "list_recent_tabs",
            arguments: .object(["limit": .int(5)]),
            sessionId: "test-session",
            token: nil
        )
        #expect(result.isError == nil)
        #expect(result.content.first?.type == "text")
        let payload = result.content.first?.text ?? ""
        #expect(payload.contains("\"tabs\""))
    }

    @Test("list_recent_tabs requires read scope only")
    func listRecentTabsScope() async throws {
        let handler = makeHandler()
        let token = makeToken(permissions: .readOnly)
        let result = try await handler.handleToolCall(
            name: "list_recent_tabs",
            arguments: nil,
            sessionId: "test-session",
            token: token
        )
        #expect(result.isError == nil)
    }

    // MARK: - search_query_history

    @Test("search_query_history rejects missing query parameter")
    func searchQueryHistoryRequiresQuery() async {
        let handler = makeHandler()
        do {
            _ = try await handler.handleToolCall(
                name: "search_query_history",
                arguments: nil,
                sessionId: "test-session",
                token: nil
            )
            Issue.record("Expected MCPError.invalidParams when query is missing")
        } catch let error as MCPError {
            if case .invalidParams = error {
                return
            }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("search_query_history rejects invalid connection_id UUID")
    func searchQueryHistoryRejectsInvalidUUID() async {
        let handler = makeHandler()
        do {
            _ = try await handler.handleToolCall(
                name: "search_query_history",
                arguments: .object([
                    "query": .string("SELECT"),
                    "connection_id": .string("not-a-uuid")
                ]),
                sessionId: "test-session",
                token: nil
            )
            Issue.record("Expected MCPError.invalidParams for malformed UUID")
        } catch let error as MCPError {
            if case .invalidParams = error {
                return
            }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("search_query_history with empty query returns entries object")
    func searchQueryHistoryEmptyQuery() async throws {
        let handler = makeHandler()
        let result = try await handler.handleToolCall(
            name: "search_query_history",
            arguments: .object(["query": .string(""), "limit": .int(1)]),
            sessionId: "test-session",
            token: nil
        )
        #expect(result.isError == nil)
        let payload = result.content.first?.text ?? ""
        #expect(payload.contains("\"entries\""))
    }

    @Test("search_query_history rejects since greater than until")
    func searchQueryHistoryRejectsInvertedWindow() async {
        let handler = makeHandler()
        do {
            _ = try await handler.handleToolCall(
                name: "search_query_history",
                arguments: .object([
                    "query": .string(""),
                    "since": .double(2_000),
                    "until": .double(1_000)
                ]),
                sessionId: "test-session",
                token: nil
            )
            Issue.record("Expected MCPError.invalidParams when since > until")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("search_query_history with since/until filters by executed_at window")
    func searchQueryHistorySinceUntilFilters() async throws {
        let handler = makeHandler()
        let connId = UUID()
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3_600)
        let twoHoursAgo = now.addingTimeInterval(-7_200)
        let marker = UUID().uuidString

        let outside = QueryHistoryEntry(
            query: "SELECT outside_\(marker)",
            connectionId: connId,
            databaseName: "testdb",
            executedAt: twoHoursAgo,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
        let inside = QueryHistoryEntry(
            query: "SELECT inside_\(marker)",
            connectionId: connId,
            databaseName: "testdb",
            executedAt: oneHourAgo,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
        _ = await QueryHistoryStorage.shared.addHistory(outside)
        _ = await QueryHistoryStorage.shared.addHistory(inside)

        let result = try await handler.handleToolCall(
            name: "search_query_history",
            arguments: .object([
                "query": .string(marker),
                "connection_id": .string(connId.uuidString),
                "since": .double(now.addingTimeInterval(-5_400).timeIntervalSince1970),
                "until": .double(now.timeIntervalSince1970)
            ]),
            sessionId: "test-session",
            token: nil
        )
        #expect(result.isError == nil)
        let payload = result.content.first?.text ?? ""
        #expect(payload.contains("inside_\(marker)"))
        #expect(!payload.contains("outside_\(marker)"))
    }

    // MARK: - open_connection_window

    @Test("open_connection_window rejects missing connection_id")
    func openConnectionWindowRequiresConnectionId() async {
        let handler = makeHandler()
        do {
            _ = try await handler.handleToolCall(
                name: "open_connection_window",
                arguments: nil,
                sessionId: "test-session",
                token: nil
            )
            Issue.record("Expected MCPError.invalidParams")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("open_connection_window rejects unknown connection")
    func openConnectionWindowRejectsUnknown() async throws {
        let handler = makeHandler()
        do {
            _ = try await handler.handleToolCall(
                name: "open_connection_window",
                arguments: .object(["connection_id": .string(UUID().uuidString)]),
                sessionId: "test-session",
                token: nil
            )
            Issue.record("Expected MCPError.notFound for unknown connection")
        } catch let error as MCPError {
            if case .notFound = error { return }
            Issue.record("Expected notFound, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("open_connection_window denies read-only token")
    func openConnectionWindowReadOnlyDenied() async throws {
        let handler = makeHandler()
        let token = makeToken(permissions: .readOnly)
        do {
            _ = try await handler.handleToolCall(
                name: "open_connection_window",
                arguments: .object(["connection_id": .string(UUID().uuidString)]),
                sessionId: "test-session",
                token: token
            )
            Issue.record("Expected MCPError.forbidden for read-only token")
        } catch let error as MCPError {
            if case .forbidden = error { return }
            Issue.record("Expected forbidden, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("open_connection_window respects token connection allowlist")
    func openConnectionWindowAllowlist() async throws {
        let handler = makeHandler()
        let connection = DatabaseConnection(name: "Test", type: .mysql)
        try await withConnections([connection]) {
            let token = makeToken(
                permissions: .readWrite,
                allowedConnectionIds: [UUID()]
            )
            do {
                _ = try await handler.handleToolCall(
                    name: "open_connection_window",
                    arguments: .object(["connection_id": .string(connection.id.uuidString)]),
                    sessionId: "test-session",
                    token: token
                )
                Issue.record("Expected MCPError.forbidden for disallowed connection")
            } catch let error as MCPError {
                if case .forbidden = error { return }
                Issue.record("Expected forbidden, got \(error)")
            } catch {
                Issue.record("Expected MCPError, got \(error)")
            }
        }
    }

    // MARK: - open_table_tab

    @Test("open_table_tab requires table_name")
    func openTableTabRequiresTableName() async {
        let handler = makeHandler()
        do {
            _ = try await handler.handleToolCall(
                name: "open_table_tab",
                arguments: .object(["connection_id": .string(UUID().uuidString)]),
                sessionId: "test-session",
                token: nil
            )
            Issue.record("Expected MCPError.invalidParams")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    // MARK: - focus_query_tab

    @Test("focus_query_tab returns notFound when tab is not open")
    func focusQueryTabNotFound() async {
        let handler = makeHandler()
        do {
            _ = try await handler.handleToolCall(
                name: "focus_query_tab",
                arguments: .object(["tab_id": .string(UUID().uuidString)]),
                sessionId: "test-session",
                token: nil
            )
            Issue.record("Expected MCPError.notFound")
        } catch let error as MCPError {
            if case .notFound = error { return }
            Issue.record("Expected notFound, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("focus_query_tab requires read-write token")
    func focusQueryTabRequiresWriteScope() async {
        let handler = makeHandler()
        let token = makeToken(permissions: .readOnly)
        do {
            _ = try await handler.handleToolCall(
                name: "focus_query_tab",
                arguments: .object(["tab_id": .string(UUID().uuidString)]),
                sessionId: "test-session",
                token: token
            )
            Issue.record("Expected MCPError.forbidden for read-only token")
        } catch let error as MCPError {
            if case .forbidden = error { return }
            Issue.record("Expected forbidden, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    // MARK: - Unknown tool

    @Test("Unknown tool name throws methodNotFound")
    func unknownToolThrows() async {
        let handler = makeHandler()
        do {
            _ = try await handler.handleToolCall(
                name: "totally_made_up_tool",
                arguments: nil,
                sessionId: "test-session",
                token: nil
            )
            Issue.record("Expected methodNotFound")
        } catch let error as MCPError {
            if case .methodNotFound = error { return }
            Issue.record("Expected methodNotFound, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }
}
