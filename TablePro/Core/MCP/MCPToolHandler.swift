//
//  MCPToolHandler.swift
//  TablePro
//

import Foundation
import os

final class MCPToolHandler: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPToolHandler")

    private let bridge: MCPConnectionBridge
    private let authGuard: MCPAuthGuard

    init(bridge: MCPConnectionBridge, authGuard: MCPAuthGuard) {
        self.bridge = bridge
        self.authGuard = authGuard
    }

    // MARK: - Dispatch

    func handleToolCall(name: String, arguments: JSONValue?, sessionId: String) async throws -> MCPToolResult {
        switch name {
        case "list_connections":
            return try await handleListConnections()
        case "connect":
            return try await handleConnect(arguments, sessionId: sessionId)
        case "disconnect":
            return try await handleDisconnect(arguments)
        case "get_connection_status":
            return try await handleGetConnectionStatus(arguments)
        case "execute_query":
            return try await handleExecuteQuery(arguments, sessionId: sessionId)
        case "list_tables":
            return try await handleListTables(arguments, sessionId: sessionId)
        case "describe_table":
            return try await handleDescribeTable(arguments, sessionId: sessionId)
        case "list_databases":
            return try await handleListDatabases(arguments, sessionId: sessionId)
        case "list_schemas":
            return try await handleListSchemas(arguments, sessionId: sessionId)
        case "get_table_ddl":
            return try await handleGetTableDDL(arguments, sessionId: sessionId)
        case "export_data":
            return try await handleExportData(arguments, sessionId: sessionId)
        case "switch_database":
            return try await handleSwitchDatabase(arguments, sessionId: sessionId)
        case "switch_schema":
            return try await handleSwitchSchema(arguments, sessionId: sessionId)
        default:
            throw MCPError.methodNotFound(name)
        }
    }

    // MARK: - Connection Tools

    private func handleListConnections() async throws -> MCPToolResult {
        let result = await bridge.listConnections()
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleConnect(_ args: JSONValue?, sessionId: String) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)
        let result = try await bridge.connect(connectionId: connectionId)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleDisconnect(_ args: JSONValue?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        try await bridge.disconnect(connectionId: connectionId)
        let result: JSONValue = .object(["status": "disconnected"])
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleGetConnectionStatus(_ args: JSONValue?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let result = try await bridge.getConnectionStatus(connectionId: connectionId)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    // MARK: - Query Execution

    private func handleExecuteQuery(_ args: JSONValue?, sessionId: String) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let query = try requireString(args, key: "query")
        let mcpSettings = await MainActor.run { AppSettingsManager.shared.mcp }
        let maxRows = optionalInt(args, key: "max_rows", default: mcpSettings.defaultRowLimit, clamp: 1...mcpSettings.maxRowLimit)
        let timeoutSeconds = optionalInt(args, key: "timeout_seconds", default: mcpSettings.queryTimeoutSeconds, clamp: 1...300)
        let database = optionalString(args, key: "database")
        let schema = optionalString(args, key: "schema")

        guard (query as NSString).length <= 102_400 else {
            throw MCPError.invalidParams("Query exceeds 100KB limit")
        }

        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        let (databaseType, safeModeLevel, databaseName) = try await resolveConnectionMeta(connectionId)

        if let database {
            _ = try await bridge.switchDatabase(connectionId: connectionId, database: database)
        }
        if let schema {
            _ = try await bridge.switchSchema(connectionId: connectionId, schema: schema)
        }

        try await authGuard.checkQueryPermission(
            sql: query,
            connectionId: connectionId,
            databaseType: databaseType,
            safeModeLevel: safeModeLevel
        )

        let startTime = Date()
        let result: JSONValue
        do {
            result = try await bridge.executeQuery(
                connectionId: connectionId,
                query: query,
                maxRows: maxRows,
                timeoutSeconds: timeoutSeconds
            )
            let elapsed = Date().timeIntervalSince(startTime)
            await authGuard.logQuery(
                sql: query,
                connectionId: connectionId,
                databaseName: databaseName,
                executionTime: elapsed,
                rowCount: result["row_count"]?.intValue ?? 0,
                wasSuccessful: true,
                errorMessage: nil
            )
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            await authGuard.logQuery(
                sql: query,
                connectionId: connectionId,
                databaseName: databaseName,
                executionTime: elapsed,
                rowCount: 0,
                wasSuccessful: false,
                errorMessage: error.localizedDescription
            )
            throw error
        }

        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    // MARK: - Schema Tools

    private func handleListTables(_ args: JSONValue?, sessionId: String) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let includeRowCounts = optionalBool(args, key: "include_row_counts", default: false)
        let database = optionalString(args, key: "database")
        let schema = optionalString(args, key: "schema")

        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        if let database {
            _ = try await bridge.switchDatabase(connectionId: connectionId, database: database)
        }
        if let schema {
            _ = try await bridge.switchSchema(connectionId: connectionId, schema: schema)
        }

        let result = try await bridge.listTables(connectionId: connectionId, includeRowCounts: includeRowCounts)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleDescribeTable(_ args: JSONValue?, sessionId: String) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let table = try requireString(args, key: "table")
        let schema = optionalString(args, key: "schema")

        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        let result = try await bridge.describeTable(connectionId: connectionId, table: table, schema: schema)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleListDatabases(_ args: JSONValue?, sessionId: String) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)
        let result = try await bridge.listDatabases(connectionId: connectionId)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleListSchemas(_ args: JSONValue?, sessionId: String) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let database = optionalString(args, key: "database")

        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        if let database {
            _ = try await bridge.switchDatabase(connectionId: connectionId, database: database)
        }

        let result = try await bridge.listSchemas(connectionId: connectionId)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleGetTableDDL(_ args: JSONValue?, sessionId: String) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let table = try requireString(args, key: "table")
        let schema = optionalString(args, key: "schema")

        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        let result = try await bridge.getTableDDL(connectionId: connectionId, table: table, schema: schema)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    // MARK: - Export

    private func handleExportData(_ args: JSONValue?, sessionId: String) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let format = try requireString(args, key: "format")
        let query = optionalString(args, key: "query")
        let tables = optionalStringArray(args, key: "tables")
        let outputPath = optionalString(args, key: "output_path")
        let maxRows = optionalInt(args, key: "max_rows", default: 50_000, clamp: 1...100_000)

        guard ["csv", "json", "sql"].contains(format) else {
            throw MCPError.invalidParams("Unsupported format: \(format). Must be csv, json, or sql")
        }

        guard query != nil || tables != nil else {
            throw MCPError.invalidParams("Either 'query' or 'tables' must be provided")
        }

        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        var queries: [(label: String, sql: String)] = []

        if let query {
            let (databaseType, safeModeLevel, _) = try await resolveConnectionMeta(connectionId)
            try await authGuard.checkQueryPermission(
                sql: query,
                connectionId: connectionId,
                databaseType: databaseType,
                safeModeLevel: safeModeLevel
            )
            queries.append((label: "query", sql: query))
        } else if let tables {
            for table in tables {
                queries.append((label: table, sql: "SELECT * FROM \(table) LIMIT \(maxRows)"))
            }
        }

        var exportResults: [JSONValue] = []
        var totalRowsExported = 0

        for (label, sql) in queries {
            let result = try await bridge.executeQuery(
                connectionId: connectionId,
                query: sql,
                maxRows: maxRows,
                timeoutSeconds: 60
            )

            guard let columns = result["columns"]?.arrayValue,
                  let rows = result["rows"]?.arrayValue
            else {
                throw MCPError.internalError("Unexpected query result structure")
            }

            let columnNames = columns.compactMap(\.stringValue)
            let formatted: String

            switch format {
            case "csv":
                formatted = formatCSV(columns: columnNames, rows: rows)
            case "json":
                formatted = formatJSON(columns: columnNames, rows: rows)
            case "sql":
                formatted = formatSQL(table: label, columns: columnNames, rows: rows)
            default:
                formatted = formatCSV(columns: columnNames, rows: rows)
            }

            totalRowsExported += rows.count

            exportResults.append(.object([
                "label": .string(label),
                "format": .string(format),
                "row_count": result["row_count"] ?? .int(0),
                "data": .string(formatted)
            ]))
        }

        // If output_path is provided, write to file
        if let outputPath {
            let fullContent: String
            if exportResults.count == 1,
               let data = exportResults.first?["data"]?.stringValue
            {
                fullContent = data
            } else {
                fullContent = exportResults.compactMap { $0["data"]?.stringValue }.joined(separator: "\n\n")
            }

            let fileURL = URL(fileURLWithPath: outputPath)
            try fullContent.write(to: fileURL, atomically: true, encoding: .utf8)

            let response: JSONValue = .object([
                "path": .string(outputPath),
                "rows_exported": .int(totalRowsExported)
            ])
            return MCPToolResult(content: [.text(encodeJSON(response))], isError: nil)
        }

        // Return inline data
        let response: JSONValue
        if exportResults.count == 1, let single = exportResults.first {
            response = single
        } else {
            response = .object(["exports": .array(exportResults)])
        }

        return MCPToolResult(content: [.text(encodeJSON(response))], isError: nil)
    }

    // MARK: - Database/Schema Switching

    private func handleSwitchDatabase(_ args: JSONValue?, sessionId: String) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let database = try requireString(args, key: "database")

        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        let result = try await bridge.switchDatabase(connectionId: connectionId, database: database)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleSwitchSchema(_ args: JSONValue?, sessionId: String) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let schema = try requireString(args, key: "schema")

        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        let result = try await bridge.switchSchema(connectionId: connectionId, schema: schema)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    // MARK: - Parameter Helpers

    private func requireUUID(_ args: JSONValue?, key: String) throws -> UUID {
        guard let value = args?[key]?.stringValue else {
            throw MCPError.invalidParams("Missing required parameter: \(key)")
        }
        guard let uuid = UUID(uuidString: value) else {
            throw MCPError.invalidParams("Invalid UUID for parameter: \(key)")
        }
        return uuid
    }

    private func requireString(_ args: JSONValue?, key: String) throws -> String {
        guard let value = args?[key]?.stringValue else {
            throw MCPError.invalidParams("Missing required parameter: \(key)")
        }
        return value
    }

    private func optionalString(_ args: JSONValue?, key: String) -> String? {
        args?[key]?.stringValue
    }

    private func optionalInt(_ args: JSONValue?, key: String, default defaultValue: Int, clamp range: ClosedRange<Int>) -> Int {
        guard let value = args?[key]?.intValue else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func optionalBool(_ args: JSONValue?, key: String, default defaultValue: Bool) -> Bool {
        args?[key]?.boolValue ?? defaultValue
    }

    private func optionalStringArray(_ args: JSONValue?, key: String) -> [String]? {
        guard let array = args?[key]?.arrayValue else { return nil }
        let strings = array.compactMap(\.stringValue)
        return strings.isEmpty ? nil : strings
    }

    // MARK: - Connection Metadata

    private func resolveConnectionMeta(_ connectionId: UUID) async throws -> (DatabaseType, SafeModeLevel, String) {
        try await MainActor.run {
            guard let session = DatabaseManager.shared.activeSessions[connectionId] else {
                throw MCPError.notConnected(connectionId)
            }
            return (session.connection.type, session.connection.safeModeLevel, session.activeDatabase)
        }
    }

    // MARK: - JSON Encoding

    private func encodeJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            Self.logger.warning("Failed to encode JSON value")
            return "{}"
        }
        return string
    }

    // MARK: - Export Formatters

    private func formatCSV(columns: [String], rows: [JSONValue]) -> String {
        var lines: [String] = []
        lines.append(columns.map { escapeCSVField($0) }.joined(separator: ","))

        for row in rows {
            guard let cells = row.arrayValue else { continue }
            let line = cells.map { cell -> String in
                switch cell {
                case .string(let value):
                    return escapeCSVField(value)
                case .null:
                    return ""
                case .int(let value):
                    return String(value)
                case .double(let value):
                    return String(value)
                case .bool(let value):
                    return value ? "true" : "false"
                default:
                    return escapeCSVField(encodeJSON(cell))
                }
            }
            lines.append(line.joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    private func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private func formatJSON(columns: [String], rows: [JSONValue]) -> String {
        var objects: [JSONValue] = []

        for row in rows {
            guard let cells = row.arrayValue else { continue }
            var dict: [String: JSONValue] = [:]
            for (index, column) in columns.enumerated() where index < cells.count {
                dict[column] = cells[index]
            }
            objects.append(.object(dict))
        }

        return encodeJSON(.array(objects))
    }

    private func formatSQL(table: String, columns: [String], rows: [JSONValue]) -> String {
        guard !columns.isEmpty else { return "" }

        var statements: [String] = []
        let escapedTable = "`\(table.replacingOccurrences(of: "`", with: "``"))`"
        let escapedColumns = columns.map { "`\($0.replacingOccurrences(of: "`", with: "``"))`" }
        let columnList = escapedColumns.joined(separator: ", ")

        for row in rows {
            guard let cells = row.arrayValue else { continue }
            let values = cells.map { cell -> String in
                switch cell {
                case .null:
                    return "NULL"
                case .string(let value):
                    let escaped = value
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                    return "'\(escaped)'"
                case .int(let value):
                    return String(value)
                case .double(let value):
                    return String(value)
                case .bool(let value):
                    return value ? "1" : "0"
                default:
                    let escaped = encodeJSON(cell)
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                    return "'\(escaped)'"
                }
            }
            statements.append("INSERT INTO \(escapedTable) (\(columnList)) VALUES (\(values.joined(separator: ", ")));")
        }

        return statements.joined(separator: "\n")
    }
}
