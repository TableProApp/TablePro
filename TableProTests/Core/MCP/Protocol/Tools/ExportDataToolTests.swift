//
//  ExportDataToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private actor SettingsProviderProbe {
    private(set) var callCount = 0

    func record() -> MCPSettings {
        callCount += 1
        return MCPSettings(defaultRowLimit: 42, maxRowLimit: 99)
    }
}

@Suite("ExportDataTool arguments")
struct ExportDataToolArgumentTests {
    private let tool = ExportDataTool()

    private func call(_ arguments: JsonValue, settings: MCPSettings = MCPSettings()) async throws
        -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services(settings: settings)
        )
    }

    @Test("Exporting a read needs only the read scope")
    func exportNeedsOnlyReadScope() {
        #expect(ExportDataTool.name == "export_data")
        #expect(ExportDataTool.requiredScopes == [.toolsRead])
        #expect(ExportDataTool.annotations.readOnlyHint == false)
        let required = ExportDataTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["connection_id", "format"])
        #expect(ExportDataTool.outputSchema != nil)
    }

    @Test("A missing required parameter is a protocol error, not a tool result")
    func missingParametersAreProtocolErrors() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["format": .string("csv")]))
        }
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        }
    }

    @Test("An unknown parameter is rejected rather than ignored")
    func unknownParameterIsRejected() async throws {
        do {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "format": .string("csv"),
                "query": .string("SELECT 1"),
                "compress": .bool(true)
            ]))
            Issue.record("Expected the unknown parameter to be rejected")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
            #expect(error.message.contains("compress"))
        }
    }

    @Test("A wrongly typed parameter is a protocol error, never silently ignored")
    func wronglyTypedParametersAreRejected() async throws {
        do {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "format": .string("csv"),
                "query": .int(1)
            ]))
            Issue.record("Expected a numeric query to be rejected")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
            #expect(error.message.contains("query"))
        }

        do {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "format": .string("csv"),
                "tables": .string("users")
            ]))
            Issue.record("Expected a string 'tables' to be rejected")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
        }
    }

    @Test("A malformed connection id comes back as a tool error the model can fix")
    func malformedConnectionIdIsAToolError() async throws {
        let result = try await call(.object([
            "connection_id": .string("not-a-uuid"),
            "format": .string("csv"),
            "query": .string("SELECT 1")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("An unsupported format is reported, not coerced")
    func unsupportedFormatIsReported() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "format": .string("parquet"),
            "query": .string("SELECT 1")
        ]))
        #expect(result.isError)
        let text = MCPToolTestHarness.errorText(result) ?? ""
        #expect(text.contains("csv"))
        #expect(text.contains("json"))
        #expect(text.contains("sql"))
    }

    @Test("Passing neither or both of query and tables is reported")
    func queryAndTablesAreExclusive() async throws {
        let neither = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "format": .string("csv")
        ]))
        #expect(neither.isError)

        let both = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "format": .string("csv"),
            "query": .string("SELECT 1"),
            "tables": .array([.string("users")])
        ]))
        #expect(both.isError)
    }

    @Test("An out-of-range max_rows is reported rather than silently clamped")
    func outOfRangeRowLimitIsReported() async throws {
        let result = try await call(
            .object([
                "connection_id": .string(UUID().uuidString),
                "format": .string("csv"),
                "query": .string("SELECT 1"),
                "max_rows": .int(999_999)
            ]),
            settings: MCPSettings(defaultRowLimit: 100, maxRowLimit: 500)
        )
        #expect(result.isError)
        let text = MCPToolTestHarness.errorText(result) ?? ""
        #expect(text.contains("max_rows"))
        #expect(text.contains("500"))
    }

    @Test("An unknown connection comes back as a not-found tool error")
    func unknownConnectionIsNotFound() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "format": .string("csv"),
            "query": .string("SELECT 1")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_found:") == true)
    }

    @Test("Row limits come from the configured MCP settings, read once per call")
    func limitsComeFromSettings() async throws {
        let probe = SettingsProviderProbe()
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPToolTestHarness.authPolicy(),
            settingsProvider: { await probe.record() },
            queryHistoryManager: ToolTestQueryHistoryStore()
        )

        _ = try? await tool.call(
            arguments: .object([
                "connection_id": .string(UUID().uuidString),
                "format": .string("csv"),
                "tables": .array([.string("users")])
            ]),
            context: MCPToolTestHarness.context(),
            services: services
        )

        #expect(await probe.callCount == 1)
    }
}

@Suite("ExportDataTool statement building")
struct ExportDataToolStatementTests {
    @Test("A plain read exports on Redis, MongoDB and etcd without needing a SQL dialect")
    func plainReadsExportOnNonSqlEngines() async throws {
        let cases: [(DatabaseType, String)] = [
            (.redis, "GET user:1"),
            (.mongodb, "db.users.find({})"),
            (.etcd, "get /keys")
        ]
        for (databaseType, query) in cases {
            let statements = try await ExportDataTool.buildStatements(
                query: query,
                tables: nil,
                sqlTable: nil,
                maxRows: 100,
                meta: MCPToolTestHarness.metadata(databaseType: databaseType)
            )
            #expect(statements.count == 1, "\(databaseType.rawValue) must build one statement")
            #expect(statements.first?.sql == query)
            #expect(statements.first?.label == "query")
            let classification = QueryClassifier.classify(query, databaseType: databaseType)
            #expect(
                classification.tier == .safe,
                "\(query) must stay a safe read so the export gate lets it through"
            )
            #expect(
                !classification.reachesFilesystemOrExecutesCode,
                "\(query) must not be refused as a filesystem or code-execution statement"
            )
            #expect(!QueryClassifier.isMultiStatement(query, databaseType: databaseType))
            #expect(
                !MCPStatementGate.requiresUserConsent(
                    classification: classification,
                    sql: query,
                    meta: MCPToolTestHarness.metadata(databaseType: databaseType, safeModeLevel: .silent)
                ),
                "\(query) must not need a confirmation the export path cannot ask for"
            )
        }
    }

    @Test("A query keeps its own text and is labelled by sql_table when one is given")
    func queryStatementsKeepTheirText() async throws {
        let statements = try await ExportDataTool.buildStatements(
            query: "  SELECT id FROM users  ",
            tables: nil,
            sqlTable: "public.users",
            maxRows: 10,
            meta: MCPToolTestHarness.metadata()
        )
        #expect(statements.first?.sql == "SELECT id FROM users")
        #expect(statements.first?.label == "public.users")
    }

    @Test("An empty query or an empty table list is reported")
    func emptyInputsAreReported() async throws {
        await #expect(throws: MCPToolExecutionError.self) {
            _ = try await ExportDataTool.buildStatements(
                query: "   ",
                tables: nil,
                sqlTable: nil,
                maxRows: 10,
                meta: MCPToolTestHarness.metadata()
            )
        }
        await #expect(throws: MCPToolExecutionError.self) {
            _ = try await ExportDataTool.buildStatements(
                query: nil,
                tables: [],
                sqlTable: nil,
                maxRows: 10,
                meta: MCPToolTestHarness.metadata()
            )
        }
    }

    @Test("Exporting whole tables quotes each part and over-fetches one row")
    func tableExportsQuoteAndOverFetch() async throws {
        let statements = try await ExportDataTool.buildStatements(
            query: nil,
            tables: ["public.users", "orders"],
            sqlTable: nil,
            maxRows: 100,
            meta: MCPToolTestHarness.metadata(databaseType: .postgresql)
        )
        #expect(statements.map(\.label) == ["public.users", "orders"])
        #expect(statements.first?.sql == "SELECT * FROM \"public\".\"users\" LIMIT 101")
        #expect(statements.last?.sql == "SELECT * FROM \"orders\" LIMIT 101")
    }

    @Test("Exporting whole tables on an engine with no SQL dialect is reported as unsupported")
    func tableExportsNeedADialect() async throws {
        for databaseType in [DatabaseType.redis, .mongodb, .etcd] {
            do {
                _ = try await ExportDataTool.buildStatements(
                    query: nil,
                    tables: ["users"],
                    sqlTable: nil,
                    maxRows: 10,
                    meta: MCPToolTestHarness.metadata(databaseType: databaseType)
                )
                Issue.record("\(databaseType.rawValue) has no SQL dialect and must say so")
            } catch let error as MCPToolExecutionError {
                #expect(error.code == .unsupported)
            }
        }
    }

    @Test("A table name that is not a plain identifier is refused")
    func tableNamesAreValidated() throws {
        #expect(throws: Never.self) { try ExportDataTool.validateTableName("users") }
        #expect(throws: Never.self) { try ExportDataTool.validateTableName("public.users") }
        #expect(throws: Never.self) { try ExportDataTool.validateTableName("db.public.users_2") }

        for name in ["users\"; DROP TABLE x --", "users; DROP TABLE x", "user table", "", "users`", "../etc"] {
            #expect(throws: MCPToolExecutionError.self) {
                try ExportDataTool.validateTableName(name)
            }
        }
    }

    @Test("Each auto-limit style produces the clause that engine understands")
    func limitClausesFollowTheDialect() {
        #expect(
            ExportDataTool.limitedSelect(from: "\"users\"", limit: 500, style: .limit)
                == "SELECT * FROM \"users\" LIMIT 500"
        )
        #expect(
            ExportDataTool.limitedSelect(from: "[dbo].[Users]", limit: 500, style: .top)
                == "SELECT TOP 500 * FROM [dbo].[Users]"
        )
        #expect(
            ExportDataTool.limitedSelect(from: "\"SCOTT\".\"EMP\"", limit: 500, style: .fetchFirst)
                == "SELECT * FROM \"SCOTT\".\"EMP\" FETCH FIRST 500 ROWS ONLY"
        )
        #expect(
            ExportDataTool.limitedSelect(from: "\"events\"", limit: 500, style: .none)
                == "SELECT * FROM \"events\""
        )
    }

    @Test("Rendering picks the writer for the format and needs a dialect only for SQL")
    func renderingPicksTheWriter() {
        let columns = ["id", "name"]
        let rows: [JsonValue] = [.array([.int(1), .string("Ada")])]

        let csv = ExportDataTool.render(
            format: .csv,
            label: "users",
            columns: columns,
            rows: rows,
            dialect: nil
        )
        #expect(csv == "id,name\r\n1,Ada")

        let json = ExportDataTool.render(
            format: .json,
            label: "users",
            columns: columns,
            rows: rows,
            dialect: nil
        )
        #expect(json.contains("\"name\""))
        #expect(json.contains("Ada"))

        let withoutDialect = ExportDataTool.render(
            format: .sql,
            label: "users",
            columns: columns,
            rows: rows,
            dialect: nil
        )
        #expect(withoutDialect.isEmpty)
    }
}
