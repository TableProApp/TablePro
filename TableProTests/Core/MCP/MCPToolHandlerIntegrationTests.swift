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

    @Test("blockedExternalConnectionIds returns ids of connections with externalAccess == .blocked")
    func blockedExternalConnectionIdsHelper() async throws {
        let blocked = DatabaseConnection(name: "Blocked", type: .mysql, externalAccess: .blocked)
        let readOnly = DatabaseConnection(name: "ReadOnly", type: .mysql, aiPolicy: .alwaysAllow, externalAccess: .readOnly)
        let readWrite = DatabaseConnection(name: "ReadWrite", type: .mysql, externalAccess: .readWrite)
        try await withConnections([blocked, readOnly, readWrite]) {
            let ids = MCPToolHandler.blockedExternalConnectionIds()
            #expect(ids.contains(blocked.id))
            #expect(!ids.contains(readOnly.id))
            #expect(!ids.contains(readWrite.id))
        }
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

    @Test("search_query_history rejects connection_id whose externalAccess is .blocked")
    func searchQueryHistoryRejectsBlockedConnection() async throws {
        let handler = makeHandler()
        let blocked = DatabaseConnection(name: "Blocked Prod", type: .mysql, externalAccess: .blocked)
        try await withConnections([blocked]) {
            do {
                _ = try await handler.handleToolCall(
                    name: "search_query_history",
                    arguments: .object([
                        "query": .string(""),
                        "connection_id": .string(blocked.id.uuidString)
                    ]),
                    sessionId: "test-session",
                    token: nil
                )
                Issue.record("Expected MCPError.forbidden for blocked connection")
            } catch let error as MCPError {
                if case .forbidden = error { return }
                Issue.record("Expected forbidden, got \(error)")
            } catch {
                Issue.record("Expected MCPError, got \(error)")
            }
        }
    }

    @Test("search_query_history filters out blocked connections when iterating without connection_id")
    func searchQueryHistoryFiltersBlockedFromUnscopedQuery() async throws {
        let handler = makeHandler()
        let blocked = DatabaseConnection(name: "Blocked", type: .mysql, externalAccess: .blocked)
        let visible = DatabaseConnection(name: "Visible", type: .mysql, externalAccess: .readOnly)
        let marker = UUID().uuidString

        try await withConnections([blocked, visible]) {
            let blockedEntry = QueryHistoryEntry(
                query: "SELECT blocked_\(marker)",
                connectionId: blocked.id,
                databaseName: "db",
                executionTime: 0.01,
                rowCount: 1,
                wasSuccessful: true
            )
            let visibleEntry = QueryHistoryEntry(
                query: "SELECT visible_\(marker)",
                connectionId: visible.id,
                databaseName: "db",
                executionTime: 0.01,
                rowCount: 1,
                wasSuccessful: true
            )
            _ = await QueryHistoryStorage.shared.addHistory(blockedEntry)
            _ = await QueryHistoryStorage.shared.addHistory(visibleEntry)

            let result = try await handler.handleToolCall(
                name: "search_query_history",
                arguments: .object(["query": .string(marker)]),
                sessionId: "test-session",
                token: nil
            )
            #expect(result.isError == nil)
            let payload = result.content.first?.text ?? ""
            #expect(payload.contains("visible_\(marker)"))
            #expect(!payload.contains("blocked_\(marker)"))
        }
    }

    @Test("search_query_history pushes token allowlist into SQL so older allowed entries surface")
    func searchQueryHistoryAllowlistOverFlood() async throws {
        let handler = makeHandler()
        let allowedConn = DatabaseConnection(name: "Allowed", type: .mysql)
        let otherConn = DatabaseConnection(name: "Other", type: .mysql)
        let marker = UUID().uuidString
        let now = Date()

        try await withConnections([allowedConn, otherConn]) {
            let oldAllowed = QueryHistoryEntry(
                query: "SELECT old_allowed_\(marker)",
                connectionId: allowedConn.id,
                databaseName: "db",
                executedAt: now.addingTimeInterval(-3_600),
                executionTime: 0.01,
                rowCount: 1,
                wasSuccessful: true
            )
            _ = await QueryHistoryStorage.shared.addHistory(oldAllowed)

            for index in 0..<20 {
                let recentOther = QueryHistoryEntry(
                    query: "SELECT recent_other_\(marker)_\(index)",
                    connectionId: otherConn.id,
                    databaseName: "db",
                    executedAt: now.addingTimeInterval(Double(index)),
                    executionTime: 0.01,
                    rowCount: 1,
                    wasSuccessful: true
                )
                _ = await QueryHistoryStorage.shared.addHistory(recentOther)
            }

            let token = makeToken(allowedConnectionIds: [allowedConn.id])
            let result = try await handler.handleToolCall(
                name: "search_query_history",
                arguments: .object(["query": .string(marker), "limit": .int(5)]),
                sessionId: "test-session",
                token: token
            )
            #expect(result.isError == nil)
            let payload = result.content.first?.text ?? ""
            #expect(payload.contains("old_allowed_\(marker)"))
            #expect(!payload.contains("recent_other_\(marker)"))
        }
    }

    @Test("QueryHistoryStorage.fetchHistory restricts results to allowedConnectionIds")
    func fetchHistoryAllowlistFilters() async throws {
        let allowedId = UUID()
        let otherId = UUID()
        let marker = UUID().uuidString

        let allowedEntry = QueryHistoryEntry(
            query: "SELECT allowed_\(marker)",
            connectionId: allowedId,
            databaseName: "db",
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
        let otherEntry = QueryHistoryEntry(
            query: "SELECT other_\(marker)",
            connectionId: otherId,
            databaseName: "db",
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
        _ = await QueryHistoryStorage.shared.addHistory(allowedEntry)
        _ = await QueryHistoryStorage.shared.addHistory(otherEntry)

        let entries = await QueryHistoryStorage.shared.fetchHistory(
            limit: 100,
            searchText: marker,
            allowedConnectionIds: [allowedId]
        )

        #expect(entries.contains { $0.query.contains("allowed_\(marker)") })
        #expect(!entries.contains { $0.query.contains("other_\(marker)") })
    }

    @Test("QueryHistoryStorage.fetchHistory returns empty when allowedConnectionIds is empty")
    func fetchHistoryEmptyAllowlistReturnsEmpty() async throws {
        let connectionId = UUID()
        let marker = UUID().uuidString
        let entry = QueryHistoryEntry(
            query: "SELECT empty_allowlist_\(marker)",
            connectionId: connectionId,
            databaseName: "db",
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
        _ = await QueryHistoryStorage.shared.addHistory(entry)

        let entries = await QueryHistoryStorage.shared.fetchHistory(
            limit: 100,
            searchText: marker,
            allowedConnectionIds: []
        )

        #expect(entries.isEmpty)
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

    @Test("switch_database against a readOnly connection returns forbidden")
    func switchDatabaseDeniedByReadOnlyExternalAccess() async throws {
        let handler = makeHandler()
        let connection = DatabaseConnection(name: "ReadOnly", type: .mysql, aiPolicy: .alwaysAllow, externalAccess: .readOnly)
        try await withConnections([connection]) {
            do {
                _ = try await handler.handleToolCall(
                    name: "switch_database",
                    arguments: .object([
                        "connection_id": .string(connection.id.uuidString),
                        "database": .string("postgres")
                    ]),
                    sessionId: "test-session",
                    token: nil
                )
                Issue.record("Expected MCPError.forbidden for readOnly externalAccess")
            } catch let error as MCPError {
                if case .forbidden = error { return }
                Issue.record("Expected forbidden, got \(error)")
            } catch {
                Issue.record("Expected MCPError, got \(error)")
            }
        }
    }

    @Test("switch_schema against a readOnly connection returns forbidden")
    func switchSchemaDeniedByReadOnlyExternalAccess() async throws {
        let handler = makeHandler()
        let connection = DatabaseConnection(name: "ReadOnly", type: .postgresql, aiPolicy: .alwaysAllow, externalAccess: .readOnly)
        try await withConnections([connection]) {
            do {
                _ = try await handler.handleToolCall(
                    name: "switch_schema",
                    arguments: .object([
                        "connection_id": .string(connection.id.uuidString),
                        "schema": .string("public")
                    ]),
                    sessionId: "test-session",
                    token: nil
                )
                Issue.record("Expected MCPError.forbidden for readOnly externalAccess")
            } catch let error as MCPError {
                if case .forbidden = error { return }
                Issue.record("Expected forbidden, got \(error)")
            } catch {
                Issue.record("Expected MCPError, got \(error)")
            }
        }
    }

    @Test("export_data against a readOnly connection returns forbidden")
    func exportDataDeniedByReadOnlyExternalAccess() async throws {
        let handler = makeHandler()
        let connection = DatabaseConnection(name: "ReadOnly", type: .mysql, aiPolicy: .alwaysAllow, externalAccess: .readOnly)
        try await withConnections([connection]) {
            do {
                _ = try await handler.handleToolCall(
                    name: "export_data",
                    arguments: .object([
                        "connection_id": .string(connection.id.uuidString),
                        "format": .string("csv"),
                        "tables": .array([.string("users")])
                    ]),
                    sessionId: "test-session",
                    token: nil
                )
                Issue.record("Expected MCPError.forbidden for readOnly externalAccess")
            } catch let error as MCPError {
                if case .forbidden = error { return }
                Issue.record("Expected forbidden, got \(error)")
            } catch {
                Issue.record("Expected MCPError, got \(error)")
            }
        }
    }

    @Test("open_connection_window against a readOnly connection returns forbidden")
    func openConnectionWindowDeniedByReadOnlyExternalAccess() async throws {
        let handler = makeHandler()
        let connection = DatabaseConnection(name: "ReadOnly", type: .mysql, aiPolicy: .alwaysAllow, externalAccess: .readOnly)
        try await withConnections([connection]) {
            do {
                _ = try await handler.handleToolCall(
                    name: "open_connection_window",
                    arguments: .object(["connection_id": .string(connection.id.uuidString)]),
                    sessionId: "test-session",
                    token: nil
                )
                Issue.record("Expected MCPError.forbidden for readOnly externalAccess")
            } catch let error as MCPError {
                if case .forbidden = error { return }
                Issue.record("Expected forbidden, got \(error)")
            } catch {
                Issue.record("Expected MCPError, got \(error)")
            }
        }
    }

    @Test("open_table_tab against a readOnly connection returns forbidden")
    func openTableTabDeniedByReadOnlyExternalAccess() async throws {
        let handler = makeHandler()
        let connection = DatabaseConnection(name: "ReadOnly", type: .mysql, aiPolicy: .alwaysAllow, externalAccess: .readOnly)
        try await withConnections([connection]) {
            do {
                _ = try await handler.handleToolCall(
                    name: "open_table_tab",
                    arguments: .object([
                        "connection_id": .string(connection.id.uuidString),
                        "table_name": .string("users")
                    ]),
                    sessionId: "test-session",
                    token: nil
                )
                Issue.record("Expected MCPError.forbidden for readOnly externalAccess")
            } catch let error as MCPError {
                if case .forbidden = error { return }
                Issue.record("Expected forbidden, got \(error)")
            } catch {
                Issue.record("Expected MCPError, got \(error)")
            }
        }
    }

    @Test("ExternalAccessLevel.satisfies follows blocked < readOnly < readWrite ordering")
    func externalAccessLevelSatisfiesOrdering() {
        #expect(ExternalAccessLevel.readWrite.satisfies(.readWrite))
        #expect(ExternalAccessLevel.readWrite.satisfies(.readOnly))
        #expect(ExternalAccessLevel.readOnly.satisfies(.readOnly))
        #expect(!ExternalAccessLevel.readOnly.satisfies(.readWrite))
        #expect(!ExternalAccessLevel.blocked.satisfies(.readOnly))
        #expect(!ExternalAccessLevel.blocked.satisfies(.readWrite))
    }

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
