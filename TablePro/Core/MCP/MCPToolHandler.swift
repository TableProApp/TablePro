import Foundation
import os

final class MCPToolHandler: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPToolHandler")

    private let bridge: MCPConnectionBridge
    let authGuard: MCPAuthGuard

    init(bridge: MCPConnectionBridge, authGuard: MCPAuthGuard) {
        self.bridge = bridge
        self.authGuard = authGuard
    }

    func handleToolCall(
        name: String,
        arguments: JSONValue?,
        sessionId: String,
        token: MCPAuthToken? = nil
    ) async throws -> MCPToolResult {
        if let token {
            try checkTokenToolPermission(token, toolName: name)
        }

        do {
            let result = try await dispatchTool(
                name: name,
                arguments: arguments,
                sessionId: sessionId,
                token: token
            )
            logToolOutcome(name: name, token: token, arguments: arguments, outcome: .success, error: nil)
            return result
        } catch let error as MCPError {
            let outcome: AuditOutcome
            if case .forbidden = error {
                outcome = .denied
            } else {
                outcome = .error
            }
            logToolOutcome(name: name, token: token, arguments: arguments, outcome: outcome, error: error.message)
            throw error
        } catch {
            logToolOutcome(name: name, token: token, arguments: arguments, outcome: .error, error: error.localizedDescription)
            throw error
        }
    }

    private func dispatchTool(
        name: String,
        arguments: JSONValue?,
        sessionId: String,
        token: MCPAuthToken?
    ) async throws -> MCPToolResult {
        switch name {
        case "list_connections":
            return try await handleListConnections()
        case "connect":
            return try await handleConnect(arguments, sessionId: sessionId, token: token)
        case "disconnect":
            return try await handleDisconnect(arguments, token: token)
        case "get_connection_status":
            return try await handleGetConnectionStatus(arguments, token: token)
        case "execute_query":
            return try await handleExecuteQuery(arguments, sessionId: sessionId, token: token)
        case "list_tables":
            return try await handleListTables(arguments, sessionId: sessionId, token: token)
        case "describe_table":
            return try await handleDescribeTable(arguments, sessionId: sessionId, token: token)
        case "list_databases":
            return try await handleListDatabases(arguments, sessionId: sessionId, token: token)
        case "list_schemas":
            return try await handleListSchemas(arguments, sessionId: sessionId, token: token)
        case "get_table_ddl":
            return try await handleGetTableDDL(arguments, sessionId: sessionId, token: token)
        case "export_data":
            return try await handleExportData(arguments, sessionId: sessionId, token: token)
        case "confirm_destructive_operation":
            return try await handleConfirmDestructiveOperation(arguments, sessionId: sessionId, token: token)
        case "switch_database":
            return try await handleSwitchDatabase(arguments, sessionId: sessionId, token: token)
        case "switch_schema":
            return try await handleSwitchSchema(arguments, sessionId: sessionId, token: token)
        case "list_recent_tabs":
            return try await handleListRecentTabs(arguments, token: token)
        case "search_query_history":
            return try await handleSearchQueryHistory(arguments, token: token)
        case "open_connection_window":
            return try await handleOpenConnectionWindow(arguments, token: token)
        case "open_table_tab":
            return try await handleOpenTableTab(arguments, token: token)
        case "focus_query_tab":
            return try await handleFocusQueryTab(arguments, token: token)
        default:
            throw MCPError.methodNotFound(name)
        }
    }

    private func logToolOutcome(
        name: String,
        token: MCPAuthToken?,
        arguments: JSONValue?,
        outcome: AuditOutcome,
        error: String?
    ) {
        let connectionId = arguments?["connection_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        MCPAuditLogger.logToolCalled(
            tokenId: token?.id,
            tokenName: token?.name,
            toolName: name,
            connectionId: connectionId,
            outcome: outcome,
            errorMessage: error
        )
    }

    private func checkTokenToolPermission(_ token: MCPAuthToken, toolName: String) throws {
        let required = minimumPermission(for: toolName)
        guard token.permissions.satisfies(required) else {
            throw MCPError.forbidden(
                "Token '\(token.name)' with permission '\(token.permissions.displayName)' "
                    + "cannot access '\(toolName)'"
            )
        }
    }

    private func minimumPermission(for toolName: String) -> TokenPermissions {
        switch toolName {
        case "confirm_destructive_operation":
            return .fullAccess
        case "switch_database", "switch_schema", "export_data",
             "open_connection_window", "open_table_tab", "focus_query_tab":
            return .readWrite
        default:
            return .readOnly
        }
    }

    func checkTokenConnectionAccess(_ token: MCPAuthToken, connectionId: UUID) throws {
        guard let allowed = token.allowedConnectionIds else { return }
        guard allowed.contains(connectionId) else {
            throw MCPError.forbidden("Token does not have access to this connection")
        }
    }

    private func handleListConnections() async throws -> MCPToolResult {
        let result = await bridge.listConnections()
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleConnect(_ args: JSONValue?, sessionId: String, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)
        let result = try await bridge.connect(connectionId: connectionId)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleDisconnect(_ args: JSONValue?, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await bridge.disconnect(connectionId: connectionId)
        let result: JSONValue = .object(["status": "disconnected"])
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleGetConnectionStatus(_ args: JSONValue?, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        let result = try await bridge.getConnectionStatus(connectionId: connectionId)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleExecuteQuery(_ args: JSONValue?, sessionId: String, token: MCPAuthToken?) async throws -> MCPToolResult {
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

        guard !QueryClassifier.isMultiStatement(query) else {
            throw MCPError.invalidParams("Multi-statement queries are not supported. Send one statement at a time.")
        }

        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        let (databaseType, safeModeLevel, databaseName) = try await resolveConnectionMeta(connectionId)

        if let database {
            _ = try await bridge.switchDatabase(connectionId: connectionId, database: database)
        }
        if let schema {
            _ = try await bridge.switchSchema(connectionId: connectionId, schema: schema)
        }

        let tier = QueryClassifier.classifyTier(query, databaseType: databaseType)

        switch tier {
        case .destructive:
            throw MCPError.forbidden(
                "Destructive queries (DROP, TRUNCATE, ALTER...DROP) cannot be executed via execute_query. "
                    + "Use the confirm_destructive_operation tool instead."
            )

        case .write, .safe:
            if let token {
                try checkTokenQueryTierPermission(token, tier: tier)
            }
            try await authGuard.checkQueryPermission(
                sql: query,
                connectionId: connectionId,
                databaseType: databaseType,
                safeModeLevel: safeModeLevel
            )
        }

        let result = try await executeAndLog(
            query: query,
            connectionId: connectionId,
            databaseName: databaseName,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            token: token
        )

        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func checkTokenQueryTierPermission(_ token: MCPAuthToken, tier: QueryTier) throws {
        switch tier {
        case .safe:
            return
        case .write:
            guard token.permissions.satisfies(.readWrite) else {
                throw MCPError.forbidden(
                    "Token '\(token.name)' with '\(token.permissions.displayName)' permission cannot execute write queries"
                )
            }
        case .destructive:
            guard token.permissions == .fullAccess else {
                throw MCPError.forbidden(
                    "Token '\(token.name)' with '\(token.permissions.displayName)' permission cannot execute destructive queries"
                )
            }
        }
    }

    private func handleConfirmDestructiveOperation(
        _ args: JSONValue?,
        sessionId: String,
        token: MCPAuthToken?
    ) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let query = try requireString(args, key: "query")
        let confirmationPhrase = try requireString(args, key: "confirmation_phrase")

        guard confirmationPhrase == "I understand this is irreversible" else {
            throw MCPError.invalidParams(
                "confirmation_phrase must be exactly: I understand this is irreversible"
            )
        }

        guard !QueryClassifier.isMultiStatement(query) else {
            throw MCPError.invalidParams(
                "Multi-statement queries are not supported. Send one statement at a time."
            )
        }

        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        let (databaseType, safeModeLevel, databaseName) = try await resolveConnectionMeta(connectionId)

        let tier = QueryClassifier.classifyTier(query, databaseType: databaseType)
        guard tier == .destructive else {
            throw MCPError.invalidParams(
                "This tool only accepts destructive queries (DROP, TRUNCATE, ALTER...DROP). "
                    + "Use execute_query for other queries."
            )
        }

        try await authGuard.checkQueryPermission(
            sql: query,
            connectionId: connectionId,
            databaseType: databaseType,
            safeModeLevel: safeModeLevel
        )

        let mcpSettings = await MainActor.run { AppSettingsManager.shared.mcp }
        let timeoutSeconds = mcpSettings.queryTimeoutSeconds

        let result = try await executeAndLog(
            query: query,
            connectionId: connectionId,
            databaseName: databaseName,
            maxRows: 0,
            timeoutSeconds: timeoutSeconds,
            token: token
        )

        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleListTables(_ args: JSONValue?, sessionId: String, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let includeRowCounts = optionalBool(args, key: "include_row_counts", default: false)
        let database = optionalString(args, key: "database")
        let schema = optionalString(args, key: "schema")

        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
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

    private func handleDescribeTable(_ args: JSONValue?, sessionId: String, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let table = try requireString(args, key: "table")
        let schema = optionalString(args, key: "schema")

        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        let result = try await bridge.describeTable(connectionId: connectionId, table: table, schema: schema)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleListDatabases(_ args: JSONValue?, sessionId: String, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)
        let result = try await bridge.listDatabases(connectionId: connectionId)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleListSchemas(_ args: JSONValue?, sessionId: String, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let database = optionalString(args, key: "database")

        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        if let database {
            _ = try await bridge.switchDatabase(connectionId: connectionId, database: database)
        }

        let result = try await bridge.listSchemas(connectionId: connectionId)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleGetTableDDL(_ args: JSONValue?, sessionId: String, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let table = try requireString(args, key: "table")
        let schema = optionalString(args, key: "schema")

        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)

        let result = try await bridge.getTableDDL(connectionId: connectionId, table: table, schema: schema)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleExportData(_ args: JSONValue?, sessionId: String, token: MCPAuthToken?) async throws -> MCPToolResult {
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

        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)
        try await authGuard.checkExternalAccessLevel(connectionId: connectionId, requires: .readWrite)

        let (databaseType, safeModeLevel, _) = try await resolveConnectionMeta(connectionId)
        var queries: [(label: String, sql: String)] = []

        if let query {
            try await authGuard.checkQueryPermission(
                sql: query,
                connectionId: connectionId,
                databaseType: databaseType,
                safeModeLevel: safeModeLevel
            )
            queries.append((label: "query", sql: query))
        } else if let tables {
            let quoteIdentifier = Self.identifierQuoter(for: databaseType)
            for table in tables {
                try Self.validateExportTableName(table)
                let quoted = Self.quoteQualifiedIdentifier(table, quoter: quoteIdentifier)
                let sql = "SELECT * FROM \(quoted) LIMIT \(maxRows)"
                try await authGuard.checkQueryPermission(
                    sql: sql,
                    connectionId: connectionId,
                    databaseType: databaseType,
                    safeModeLevel: safeModeLevel
                )
                queries.append((label: table, sql: sql))
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

        let response: JSONValue
        if exportResults.count == 1, let single = exportResults.first {
            response = single
        } else {
            response = .object(["exports": .array(exportResults)])
        }

        return MCPToolResult(content: [.text(encodeJSON(response))], isError: nil)
    }

    private func handleSwitchDatabase(_ args: JSONValue?, sessionId: String, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let database = try requireString(args, key: "database")

        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)
        try await authGuard.checkExternalAccessLevel(connectionId: connectionId, requires: .readWrite)

        let result = try await bridge.switchDatabase(connectionId: connectionId, database: database)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func handleSwitchSchema(_ args: JSONValue?, sessionId: String, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let schema = try requireString(args, key: "schema")

        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await authGuard.checkConnectionAccess(connectionId: connectionId, sessionId: sessionId)
        try await authGuard.checkExternalAccessLevel(connectionId: connectionId, requires: .readWrite)

        let result = try await bridge.switchSchema(connectionId: connectionId, schema: schema)
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    private func executeAndLog(
        query: String,
        connectionId: UUID,
        databaseName: String,
        maxRows: Int,
        timeoutSeconds: Int,
        token: MCPAuthToken? = nil
    ) async throws -> JSONValue {
        let startTime = Date()
        do {
            let result = try await bridge.executeQuery(
                connectionId: connectionId,
                query: query,
                maxRows: maxRows,
                timeoutSeconds: timeoutSeconds
            )
            let elapsed = Date().timeIntervalSince(startTime)
            let rowCount = result["row_count"]?.intValue ?? 0
            await authGuard.logQuery(
                sql: query,
                connectionId: connectionId,
                databaseName: databaseName,
                executionTime: elapsed,
                rowCount: rowCount,
                wasSuccessful: true,
                errorMessage: nil
            )
            MCPAuditLogger.logQueryExecuted(
                tokenId: token?.id,
                tokenName: token?.name,
                connectionId: connectionId,
                sql: query,
                durationMs: Int(elapsed * 1_000),
                rowCount: rowCount,
                outcome: .success
            )
            return result
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
            MCPAuditLogger.logQueryExecuted(
                tokenId: token?.id,
                tokenName: token?.name,
                connectionId: connectionId,
                sql: query,
                durationMs: Int(elapsed * 1_000),
                rowCount: 0,
                outcome: .error,
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }

    func requireUUID(_ args: JSONValue?, key: String) throws -> UUID {
        guard let value = args?[key]?.stringValue else {
            throw MCPError.invalidParams("Missing required parameter: \(key)")
        }
        guard let uuid = UUID(uuidString: value) else {
            throw MCPError.invalidParams("Invalid UUID for parameter: \(key)")
        }
        return uuid
    }

    func requireString(_ args: JSONValue?, key: String) throws -> String {
        guard let value = args?[key]?.stringValue else {
            throw MCPError.invalidParams("Missing required parameter: \(key)")
        }
        return value
    }

    func optionalString(_ args: JSONValue?, key: String) -> String? {
        args?[key]?.stringValue
    }

    func optionalInt(_ args: JSONValue?, key: String, default defaultValue: Int, clamp range: ClosedRange<Int>) -> Int {
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

    private func resolveConnectionMeta(_ connectionId: UUID) async throws -> (DatabaseType, SafeModeLevel, String) {
        try await MainActor.run {
            guard let session = DatabaseManager.shared.activeSessions[connectionId] else {
                throw MCPError.notConnected(connectionId)
            }
            return (session.connection.type, session.connection.safeModeLevel, session.activeDatabase)
        }
    }

    static func validateExportTableName(_ table: String) throws {
        let pattern = "^[A-Za-z0-9_][A-Za-z0-9_.]*$"
        guard table.range(of: pattern, options: .regularExpression) != nil else {
            throw MCPError.invalidParams(
                "Invalid table name: '\(table)'. Allowed characters: letters, digits, underscore, and '.' for schema-qualified names."
            )
        }
    }

    static func identifierQuoter(for databaseType: DatabaseType) -> (String) -> String {
        if let dialect = try? resolveSQLDialect(for: databaseType) {
            return quoteIdentifierFromDialect(dialect)
        }
        return { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    }

    static func quoteQualifiedIdentifier(_ identifier: String, quoter: (String) -> String) -> String {
        identifier.split(separator: ".", omittingEmptySubsequences: false)
            .map { quoter(String($0)) }
            .joined(separator: ".")
    }

    func encodeJSON(_ value: JSONValue) -> String {
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
