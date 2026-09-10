//
//  SearchQueryHistoryToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SearchQueryHistoryTool")
struct SearchQueryHistoryToolTests {
    private let tool = SearchQueryHistoryTool()
    private let granted = UUID()
    private let withheld = UUID()

    private func entry(connectionId: UUID, query: String, errorMessage: String? = nil) -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: "shop",
            databaseType: .postgresql,
            source: .mcp,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: errorMessage == nil,
            errorMessage: errorMessage
        )
    }

    private func store(errorMessage: String? = nil) -> ToolTestQueryHistoryStore {
        ToolTestQueryHistoryStore(entries: [
            entry(connectionId: granted, query: "SELECT 1", errorMessage: errorMessage),
            entry(connectionId: withheld, query: "SELECT secret FROM payroll")
        ])
    }

    private func call(
        _ arguments: JsonValue,
        access: ConnectionAccess,
        store: ToolTestQueryHistoryStore,
        withheldPolicy: AIConnectionPolicy = .alwaysAllow
    ) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(
                principal: MCPToolTestHarness.principal(access: access)
            ),
            services: MCPToolTestHarness.services(
                authPolicy: MCPToolTestHarness.authPolicy(connections: [
                    granted: MCPToolTestHarness.snapshot(name: "Granted"),
                    withheld: MCPToolTestHarness.snapshot(policy: withheldPolicy, name: "Withheld")
                ]),
                history: store
            )
        )
    }

    @Test("Searching history is read-only and requires a search term")
    func metadata() {
        #expect(SearchQueryHistoryTool.name == "search_query_history")
        #expect(SearchQueryHistoryTool.requiredScopes == [.toolsRead])
        #expect(SearchQueryHistoryTool.annotations.readOnlyHint == true)
        #expect(
            SearchQueryHistoryTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) == ["query"]
        )
    }

    @Test("Missing query is a protocol error")
    func missingQuery() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([:]), access: .all, store: store())
        }
    }

    @Test("A malformed connection id is a tool error")
    func malformedConnectionId() async throws {
        let result = try await call(
            .object(["query": .string("SELECT"), "connection_id": .string("not-a-uuid")]),
            access: .all,
            store: store()
        )
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("A since later than until is reported")
    func invertedDateRangeIsReported() async throws {
        let result = try await call(
            .object([
                "query": .string("SELECT"),
                "since": .double(2_000),
                "until": .double(1_000)
            ]),
            access: .all,
            store: store()
        )
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.contains("since") == true)
    }

    @Test("A token with no readable connection gets nothing and the store is never asked")
    func noReadableConnectionsReturnsNothing() async throws {
        let historyStore = store()
        let result = try await call(
            .object(["query": .string("SELECT")]),
            access: .limited([]),
            store: historyStore
        )
        #expect(!result.isError)
        #expect(result.structuredContent?["entries"]?.arrayValue?.isEmpty == true)
        #expect(await historyStore.receivedFilters.isEmpty)
    }

    @Test("The search is bounded by the connections the token may read")
    func searchIsBoundedByTheGrant() async throws {
        let historyStore = store()
        let result = try await call(
            .object(["query": .string("SELECT")]),
            access: .limited([granted]),
            store: historyStore
        )
        #expect(!result.isError)

        let filters = await historyStore.receivedFilters
        #expect(filters.count == 1)
        #expect(filters.first?.allowedConnectionIds == [granted])

        let entries = try #require(result.structuredContent?["entries"]?.arrayValue)
        #expect(entries.count == 1)
        #expect(entries.first?["connection_id"]?.stringValue == granted.uuidString)
        for entry in entries {
            #expect(entry["query"]?.stringValue?.contains("payroll") != true)
            #expect(entry["connection_id"]?.stringValue != withheld.uuidString)
        }
    }

    @Test("Naming a connection outside the grant is refused")
    func namingAWithheldConnectionIsRefused() async throws {
        let result = try await call(
            .object([
                "query": .string("SELECT"),
                "connection_id": .string(withheld.uuidString)
            ]),
            access: .limited([granted]),
            store: store()
        )
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("denied:") == true)
    }

    @Test("A connection the user set to never share with AI is refused")
    func aiPolicyNeverIsRefused() async throws {
        let result = try await call(
            .object([
                "query": .string("SELECT"),
                "connection_id": .string(withheld.uuidString)
            ]),
            access: .all,
            store: store(),
            withheldPolicy: .never
        )
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("denied:") == true)
    }

    @Test("Naming a connection narrows the allowlist to that one connection")
    func namingAConnectionNarrowsTheAllowlist() async throws {
        let historyStore = store()
        _ = try await call(
            .object([
                "query": .string("SELECT"),
                "connection_id": .string(granted.uuidString)
            ]),
            access: .all,
            store: historyStore
        )
        let filters = await historyStore.receivedFilters
        #expect(filters.first?.allowedConnectionIds == [granted])
        #expect(filters.first?.scope == .connection(granted))
    }

    @Test("A recorded failure is redacted before it reaches the client")
    func recordedFailuresAreRedacted() async throws {
        let result = try await call(
            .object(["query": .string("SELECT")]),
            access: .limited([granted]),
            store: store(errorMessage: "could not connect to 10.0.0.5:5432 as user admin")
        )
        let entries = try #require(result.structuredContent?["entries"]?.arrayValue)
        let message = try #require(entries.first?["error_message"]?.stringValue)
        #expect(!message.contains("10.0.0.5"))
        #expect(message.contains("[redacted]"))
    }

    @Test("A limit outside the documented range is reported")
    func limitOutsideRangeIsReported() async throws {
        let result = try await call(
            .object(["query": .string("SELECT"), "limit": .int(1_000)]),
            access: .all,
            store: store()
        )
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.contains("limit") == true)
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(
                .object(["query": .string("SELECT"), "database": .string("shop")]),
                access: .all,
                store: store()
            )
        }
    }
}
