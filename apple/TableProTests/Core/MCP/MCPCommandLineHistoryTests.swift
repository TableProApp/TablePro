import Foundation
@testable import TablePro
import TableProMCP
import Testing

private final class RecordingHistory: QueryHistoryRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [QueryHistoryRecordRequest] = []

    var requests: [QueryHistoryRecordRequest] { lock.withLock { recorded } }

    func record(_ request: QueryHistoryRecordRequest) async -> Bool {
        lock.withLock { recorded.append(request) }
        return true
    }
}

struct MCPCommandLineHistoryTests {
    @Test("A request from the tablepro command is filed under Command Line, any other under MCP")
    func sourceFollowsTheClient() {
        let cli = MCPToolTestHarness.context(clientInfo: MCPImplementation(name: CLIClientIdentity.name, version: "1"))
        let other = MCPToolTestHarness.context(clientInfo: MCPImplementation(name: "claude-code", version: "2"))
        #expect(ToolQueryExecutor.historySource(for: cli) == .commandLine)
        #expect(ToolQueryExecutor.historySource(for: other) == .mcp)
    }

    @Test("A command line query is recorded under its own source")
    func commandLineQueryIsRecorded() async {
        let history = RecordingHistory()
        let connectionId = UUID()
        let policy = MCPAuthPolicy(
            connectionResolver: { _ in MCPToolTestHarness.snapshot() },
            historyRecorder: history
        )
        await policy.logQuery(
            sql: "SELECT 1",
            connectionId: connectionId,
            databaseName: "shop",
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true,
            errorMessage: nil,
            source: .commandLine
        )
        let recorded = history.requests
        #expect(recorded.count == 1)
        #expect(recorded.first?.source == .commandLine)
        #expect(recorded.first?.connectionId == connectionId)
    }
}

extension GlobalStateSuites {
    struct MCPCommandLineHistorySettingTests {
        @Test("Turning off MCP history leaves command line queries recorded", .appSettings {
            $0.mcp.logQueriesInHistory = false
        })
        func settingGovernsOnlyMcp() async {
            let history = RecordingHistory()
            let policy = MCPAuthPolicy(
                connectionResolver: { _ in MCPToolTestHarness.snapshot() },
                historyRecorder: history
            )
            for source in [QueryHistorySource.mcp, .commandLine] {
                await policy.logQuery(
                    sql: "SELECT 1",
                    connectionId: UUID(),
                    databaseName: "shop",
                    executionTime: 0,
                    rowCount: 1,
                    wasSuccessful: true,
                    errorMessage: nil,
                    source: source
                )
            }
            #expect(history.requests.map(\.source) == [.commandLine])
        }
    }
}
