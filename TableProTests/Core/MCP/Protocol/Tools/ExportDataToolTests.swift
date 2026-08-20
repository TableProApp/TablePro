import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

private actor SettingsProviderProbe {
    private(set) var callCount = 0

    func record() -> MCPSettings {
        callCount += 1
        return MCPSettings(defaultRowLimit: 42, maxRowLimit: 99)
    }
}

@Suite("ExportDataTool")
struct ExportDataToolTests {
    @Test("Export resolves its row limit from the configured MCP settings")
    func resolvesLimitsFromSettings() async throws {
        let probe = SettingsProviderProbe()
        let tool = ExportDataTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(),
            settingsProvider: { await probe.record() }
        )

        _ = try? await tool.call(
            arguments: .object([
                "connection_id": .string(UUID().uuidString),
                "format": .string("csv"),
                "tables": .array([.string("users")])
            ]),
            context: context,
            services: services
        )

        #expect(await probe.callCount == 1)
    }

    @Test("Tool exposes expected metadata")
    func metadata() {
        #expect(ExportDataTool.name == "export_data")
        #expect(ExportDataTool.requiredScopes == [.toolsRead])
        let schema = ExportDataTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required == ["connection_id", "format"])
    }

    @Test("Missing connection_id returns invalidParams")
    func missingConnectionId() async throws {
        let tool = ExportDataTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object(["format": .string("csv")]),
                context: context,
                services: services
            )
        }
    }

    @Test("Missing format returns invalidParams")
    func missingFormat() async throws {
        let tool = ExportDataTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object(["connection_id": .string(UUID().uuidString)]),
                context: context,
                services: services
            )
        }
    }

    @Test("Malformed connection_id returns invalidParams")
    func malformedConnectionId() async throws {
        let tool = ExportDataTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string("not-a-uuid"),
                    "format": .string("csv"),
                    "query": .string("SELECT 1")
                ]),
                context: context,
                services: services
            )
        }
    }

    @Test("An over-fetched extra row marks the export truncated and is trimmed off")
    func overFetchedRowMarksTruncation() {
        let fetched = (0..<501).map { JsonValue.int($0) }
        let limited = ExportDataTool.applyRowLimit(to: fetched, maxRows: 500, driverReportedTruncation: false)
        #expect(limited.rows.count == 500)
        #expect(limited.isTruncated)
    }

    @Test("A result that fits the limit is not marked truncated")
    func resultWithinLimitIsNotTruncated() {
        let fetched = (0..<300).map { JsonValue.int($0) }
        let limited = ExportDataTool.applyRowLimit(to: fetched, maxRows: 500, driverReportedTruncation: false)
        #expect(limited.rows.count == 300)
        #expect(!limited.isTruncated)
    }

    @Test("A result exactly at the limit is not marked truncated")
    func resultExactlyAtLimitIsNotTruncated() {
        let fetched = (0..<500).map { JsonValue.int($0) }
        let limited = ExportDataTool.applyRowLimit(to: fetched, maxRows: 500, driverReportedTruncation: false)
        #expect(limited.rows.count == 500)
        #expect(!limited.isTruncated)
    }

    @Test("Driver-reported truncation is preserved when the row count fits")
    func driverTruncationIsPreserved() {
        let fetched = (0..<500).map { JsonValue.int($0) }
        let limited = ExportDataTool.applyRowLimit(to: fetched, maxRows: 500, driverReportedTruncation: true)
        #expect(limited.rows.count == 500)
        #expect(limited.isTruncated)
    }

    @Test("LIMIT dialects append a trailing LIMIT clause")
    func limitDialectUsesLimitClause() {
        let sql = ExportDataTool.limitedSelectAll(from: "\"users\"", limit: 500, autoLimitStyle: .limit)
        #expect(sql == "SELECT * FROM \"users\" LIMIT 500")
    }

    @Test("TOP dialects put the limit before the column list")
    func topDialectUsesTopClause() {
        let sql = ExportDataTool.limitedSelectAll(from: "[dbo].[Users]", limit: 500, autoLimitStyle: .top)
        #expect(sql == "SELECT TOP 500 * FROM [dbo].[Users]")
        #expect(!sql.contains("LIMIT"))
    }

    @Test("FETCH FIRST dialects use the ANSI row-limit clause")
    func fetchFirstDialectUsesFetchFirst() {
        let sql = ExportDataTool.limitedSelectAll(from: "\"SCOTT\".\"EMP\"", limit: 500, autoLimitStyle: .fetchFirst)
        #expect(sql == "SELECT * FROM \"SCOTT\".\"EMP\" FETCH FIRST 500 ROWS ONLY")
        #expect(!sql.contains("LIMIT"))
    }

    @Test("Dialects without an auto-limit style emit no limit clause")
    func noneDialectEmitsNoLimitClause() {
        let sql = ExportDataTool.limitedSelectAll(from: "\"events\"", limit: 500, autoLimitStyle: .none)
        #expect(sql == "SELECT * FROM \"events\"")
    }

    @Test("Neither query nor tables returns invalidParams")
    func missingQueryAndTables() async throws {
        let tool = ExportDataTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string(UUID().uuidString),
                    "format": .string("csv")
                ]),
                context: context,
                services: services
            )
        }
    }
}
