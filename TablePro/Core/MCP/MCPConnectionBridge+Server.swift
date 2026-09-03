import Foundation
import os
import TableProPluginKit

extension MCPConnectionBridge {
    static let schemaResourceTableLimit = 100

    func listPrincipals(connectionId: UUID) async throws -> JsonValue {
        try await ensureConnected(connectionId)
        let driver = await MainActor.run { DatabaseManager.shared.principalDriver(for: connectionId) }
        guard let driver else {
            throw DatabaseAccessError.dataSourceError(
                String(localized: "This engine does not expose users and roles.")
            )
        }
        let principals = try await driver.fetchPrincipals()
        let payload = principals
            .sorted { lhs, rhs in
                lhs.ref.name == rhs.ref.name
                    ? (lhs.ref.host ?? "") < (rhs.ref.host ?? "")
                    : lhs.ref.name < rhs.ref.name
            }
            .map { principal -> JsonValue in
                var fields: [String: JsonValue] = [
                    "name": .string(principal.ref.name),
                    "is_role": .bool(principal.isRole),
                    "can_login": .bool(principal.canLogin),
                    "member_of": .array(principal.memberOf.sorted().map { .string($0) }),
                    "attributes": .array(
                        principal.attributes
                            .sorted { $0.key < $1.key }
                            .map { attribute in
                                .object([
                                    "key": .string(attribute.key),
                                    "label": .string(attribute.label),
                                    "is_enabled": .bool(attribute.isEnabled)
                                ])
                            }
                    )
                ]
                if let host = principal.ref.host {
                    fields["host"] = .string(host)
                }
                if let limit = principal.connectionLimit {
                    fields["connection_limit"] = .int(limit)
                }
                if let comment = principal.comment, !comment.isEmpty {
                    fields["comment"] = .string(comment)
                }
                return .object(fields)
            }
        return .object(["principals": .array(payload)])
    }

    func listGrants(connectionId: UUID, principal: String, host: String?) async throws -> JsonValue {
        try await ensureConnected(connectionId)
        let driver = await MainActor.run { DatabaseManager.shared.principalDriver(for: connectionId) }
        guard let driver else {
            throw DatabaseAccessError.dataSourceError(
                String(localized: "This engine does not expose users and roles.")
            )
        }
        let grants = try await driver.fetchGrants(for: PluginPrincipalRef(name: principal, host: host))
        let payload = grants
            .sorted { lhs, rhs in
                lhs.privilege == rhs.privilege
                    ? MCPConnectionBridge.scopePath(lhs.scope) < MCPConnectionBridge.scopePath(rhs.scope)
                    : lhs.privilege < rhs.privilege
            }
            .map { grant -> JsonValue in
                .object([
                    "privilege": .string(grant.privilege),
                    "scope": .string(MCPConnectionBridge.scopePath(grant.scope)),
                    "is_grantable": .bool(grant.isGrantable)
                ])
            }
        return .object([
            "principal": .string(principal),
            "grants": .array(payload)
        ])
    }

    func serverDashboard(connectionId: UUID, panels: Set<String>) async throws -> JsonValue {
        let databaseType = try await ensureConnected(connectionId)
        guard ServerDashboardQueryProviderFactory.provider(for: databaseType) != nil else {
            throw DatabaseAccessError.dataSourceError(
                String(localized: "TablePro has no server dashboard for this engine.")
            )
        }
        let scope = await MainActor.run { DatabaseManager.shared.browseScope(for: connectionId) }
        guard let scope else {
            throw DatabaseAccessError.notConnected(connectionId)
        }

        return try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            guard let provider = ServerDashboardQueryProviderFactory.provider(for: databaseType) else {
                throw DatabaseAccessError.dataSourceError(
                    String(localized: "TablePro has no server dashboard for this engine.")
                )
            }
            let execute: (String) async throws -> QueryResult = { sql in
                try await driver.execute(query: sql)
            }
            var result: [String: JsonValue] = [:]
            if panels.contains("sessions") {
                let sessions = (try? await provider.fetchSessions(execute: execute)) ?? []
                result["sessions"] = .array(sessions.map { session in
                    .object([
                        "id": .string(session.id),
                        "user": .string(session.user),
                        "database": .string(session.database),
                        "state": .string(session.state),
                        "duration_seconds": .int(session.durationSeconds),
                        "query": .string(session.query),
                        "can_kill": .bool(session.canKill),
                        "can_cancel": .bool(session.canCancel)
                    ])
                })
            }
            if panels.contains("metrics") {
                let metrics = (try? await provider.fetchMetrics(execute: execute)) ?? []
                result["metrics"] = .array(metrics.map { metric in
                    .object([
                        "id": .string(metric.id),
                        "label": .string(metric.label),
                        "value": .string(metric.value),
                        "unit": .string(metric.unit)
                    ])
                })
            }
            if panels.contains("slow_queries") {
                let slow = (try? await provider.fetchSlowQueries(execute: execute)) ?? []
                result["slow_queries"] = .array(slow.map { entry in
                    .object([
                        "duration": .string(entry.duration),
                        "query": .string(entry.query),
                        "user": .string(entry.user),
                        "database": .string(entry.database)
                    ])
                })
            }
            return .object(result)
        }
    }

    func sessionControlStatement(
        connectionId: UUID,
        processId: String,
        cancelOnly: Bool
    ) async throws -> String {
        let databaseType = try await ensureConnected(connectionId)
        guard let provider = ServerDashboardQueryProviderFactory.provider(for: databaseType) else {
            throw DatabaseAccessError.dataSourceError(
                String(localized: "TablePro has no server dashboard for this engine.")
            )
        }
        let sql = cancelOnly
            ? provider.cancelQuerySQL(processId: processId)
            : provider.killSessionSQL(processId: processId)
        guard let sql else {
            throw DatabaseAccessError.dataSourceError(
                String(localized: "This engine cannot stop a session from TablePro.")
            )
        }
        return sql
    }

    func maintenanceOperations(connectionId: UUID) async throws -> JsonValue {
        try await ensureConnected(connectionId)
        let operations = await MainActor.run {
            DatabaseManager.shared.driver(for: connectionId)?.supportedMaintenanceOperations()
        }
        return .object([
            "operations": .array((operations ?? []).sorted().map { .string($0) }),
            "is_supported": .bool(operations != nil)
        ])
    }

    func maintenanceStatements(
        connectionId: UUID,
        operation: String,
        table: String?,
        options: [String: String]
    ) async throws -> [String] {
        try await ensureConnected(connectionId)
        let statements = await MainActor.run {
            DatabaseManager.shared.driver(for: connectionId)?
                .maintenanceStatements(operation: operation, table: table, options: options)
        }
        guard let statements, !statements.isEmpty else {
            throw DatabaseAccessError.invalidArgument(
                String(localized: "That maintenance operation is not available on this connection.")
            )
        }
        return statements
    }

    func sessionContexts(connectionId: UUID) async throws -> JsonValue {
        try await ensureConnected(connectionId)
        let scope = await MainActor.run { DatabaseManager.shared.browseScope(for: connectionId) }
        guard let scope else {
            throw DatabaseAccessError.notConnected(connectionId)
        }
        let contexts = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchSessionContexts()
        }
        guard let contexts else {
            return .object(["contexts": .array([]), "is_supported": .bool(false)])
        }
        let payload = contexts.map { context -> JsonValue in
            .object([
                "id": .string(context.id),
                "label": .string(context.label),
                "value": .string(context.currentValue ?? ""),
                "options": .array(context.availableValues.map { .string($0) })
            ])
        }
        return .object(["contexts": .array(payload), "is_supported": .bool(true)])
    }

    func transactionControl(scope: DatabaseScope, action: String) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let supported = await MainActor.run {
            DatabaseManager.shared.driver(for: scope.connectionId)?.supportsTransactions ?? false
        }
        guard supported else {
            throw DatabaseAccessError.dataSourceError(
                String(localized: "This engine does not support transactions.")
            )
        }
        try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: .sessionDriver,
            cancellation: .protectedWrite
        ) { driver in
            switch action {
            case "begin": try await driver.beginTransaction(mode: .readWrite)
            case "commit": try await driver.commitTransaction()
            case "rollback": try await driver.rollbackTransaction()
            default:
                throw DatabaseAccessError.invalidArgument(
                    String(localized: "Transaction action must be begin, commit, or rollback.")
                )
            }
        }
        return .object(["status": .string(action), "connection_id": .string(scope.connectionId.uuidString)])
    }

    func fetchSchemaResource(connectionId: UUID) async throws -> JsonValue {
        try await ensureConnected(connectionId)
        let scope = await MainActor.run { DatabaseManager.shared.browseScope(for: connectionId) }
        guard let scope else {
            throw DatabaseAccessError.notConnected(connectionId)
        }

        let snapshot = try await DatabaseManager.shared.withMetadataDriver(
            scope: scope,
            workload: .bulk
        ) { driver -> (tables: [TableInfo], columns: [String: [ColumnInfo]]) in
            let tables = MCPConnectionBridge.sortedTables(try await driver.fetchTables(schema: scope.schema))
            let limited = Array(tables.prefix(MCPConnectionBridge.schemaResourceTableLimit))
            var columns: [String: [ColumnInfo]] = [:]
            for table in limited {
                columns[table.name] = (try? await driver.fetchColumns(table: table.name, schema: scope.schema)) ?? []
            }
            return (tables, columns)
        }

        let limited = Array(snapshot.tables.prefix(Self.schemaResourceTableLimit))
        let tableSchemas: [JsonValue] = limited.map { table in
            .object([
                "name": .string(table.name),
                "type": .string(table.type.rawValue),
                "schema": table.schema.map(JsonValue.string) ?? JsonValue.null,
                "columns": .array((snapshot.columns[table.name] ?? []).map(MCPConnectionBridge.encode(column:)))
            ])
        }

        var result: [String: JsonValue] = [
            "database": .string(scope.database),
            "tables": .array(tableSchemas)
        ]
        if snapshot.tables.count > Self.schemaResourceTableLimit {
            result["truncated"] = .bool(true)
            result["total_tables"] = .int(snapshot.tables.count)
        }
        return .object(result)
    }

    func fetchHistoryResource(
        connectionId: UUID,
        limit: Int,
        search: String?,
        dateFilter: String?
    ) async throws -> JsonValue {
        let calendar = Calendar.current
        let now = Date()
        let since: Date?
        switch dateFilter {
        case "today": since = calendar.startOfDay(for: now)
        case "thisWeek": since = calendar.date(byAdding: .day, value: -7, to: now)
        case "thisMonth": since = calendar.date(byAdding: .day, value: -30, to: now)
        default: since = nil
        }

        let page = await QueryHistoryManager.shared.fetch(
            QueryHistoryFilter(
                scope: .connection(connectionId),
                searchText: search,
                since: since,
                allowedConnectionIds: [connectionId]
            ),
            limit: limit
        )

        return .object(["history": .array(page.entries.map(Self.encode(historyEntry:)))])
    }

    static func scopePath(_ scope: PluginPrivilegeScope) -> String {
        switch scope {
        case .server:
            return "*"
        case .database(let database):
            return database
        case .schema(let database, let schema):
            return "\(database).\(schema)"
        case .table(let database, let schema, let table):
            return [database, schema, table].compactMap { $0 }.joined(separator: ".")
        case .column(let database, let schema, let table, let column):
            return [database, schema, table, column].compactMap { $0 }.joined(separator: ".")
        @unknown default:
            return "*"
        }
    }

    static func encode(historyEntry entry: QueryHistoryEntry) -> JsonValue {
        var fields: [String: JsonValue] = [
            "id": .string(entry.id.uuidString),
            "query": .string(entry.query),
            "connection_id": .string(entry.connectionId.uuidString),
            "database_name": .string(entry.databaseName),
            "database_type": .string(entry.databaseType.rawValue),
            "source": .string(entry.source.rawValue),
            "statement_type": .string(entry.statementType.rawValue),
            "executed_at": .string(iso8601.withLockUnchecked { $0.string(from: entry.executedAt) }),
            "execution_time_ms": .double(entry.executionTime * 1_000),
            "row_count": .int(entry.rowCount),
            "was_successful": .bool(entry.wasSuccessful)
        ]
        if let schemaName = entry.schemaName {
            fields["schema_name"] = .string(schemaName)
        }
        if let error = entry.errorMessage {
            fields["error_message"] = .string(MCPErrorRedactor.redact(error))
        }
        return .object(fields)
    }
}

extension MCPConnectionBridge {
    func createDatabase(connectionId: UUID, name: String, options: [String: String]) async throws -> JsonValue {
        let (driver, _) = try await resolveDriver(connectionId)
        try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
            try await driver.createDatabase(CreateDatabaseRequest(name: name, values: options))
        }
        return .object(["status": .string("created"), "database": .string(name)])
    }

    func dropDatabase(connectionId: UUID, name: String) async throws -> JsonValue {
        let (driver, _) = try await resolveDriver(connectionId)
        try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
            try await driver.dropDatabase(name: name)
        }
        return .object(["status": .string("dropped"), "database": .string(name)])
    }

    func dropSchema(connectionId: UUID, name: String) async throws -> JsonValue {
        let (driver, _) = try await resolveDriver(connectionId)
        try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
            try await driver.dropSchema(name: name)
        }
        return .object(["status": .string("dropped"), "schema": .string(name)])
    }

    func createDatabaseFormSpec(connectionId: UUID) async throws -> JsonValue {
        let (driver, _) = try await resolveDriver(connectionId)
        guard let spec = try await driver.createDatabaseFormSpec() else {
            return .object(["is_supported": .bool(false), "fields": .array([])])
        }
        let fields = spec.fields.map { field -> JsonValue in
            let options: [String]
            let defaultValue: String?
            switch field.kind {
            case .picker(let values, let fallback), .searchable(let values, let fallback):
                options = values.map(\.value)
                defaultValue = fallback
            }
            return .object([
                "key": .string(field.id),
                "label": .string(field.label),
                "default_value": defaultValue.map(JsonValue.string) ?? JsonValue.null,
                "options": .array(options.map { .string($0) })
            ])
        }
        return .object(["is_supported": .bool(true), "fields": .array(fields)])
    }
}
