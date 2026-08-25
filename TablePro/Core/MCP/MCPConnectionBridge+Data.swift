import Foundation
import TableProPluginKit

struct MCPBrowseRequest: Sendable {
    let table: String
    let columns: [String]?
    let filters: [TableFilter]
    let logicMode: FilterLogicMode
    let sort: [(column: String, descending: Bool)]
    let limit: Int
    let offset: Int
}

extension MCPConnectionBridge {
    func quotingRules(scope: DatabaseScope, identifiers: [String], literals: [String]) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        return try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            let quotedIdentifiers = identifiers.map { name -> JsonValue in
                .object(["input": .string(name), "quoted": .string(driver.quoteIdentifier(name))])
            }
            let escapedLiterals = literals.map { value -> JsonValue in
                .object(["input": .string(value), "escaped": .string(driver.escapeStringLiteral(value))])
            }
            return .object([
                "identifiers": .array(quotedIdentifiers),
                "literals": .array(escapedLiterals)
            ])
        }
    }

    func countRows(
        scope: DatabaseScope,
        table: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        exact: Bool
    ) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let outcome = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver
            -> (count: Int?, isApproximate: Bool) in
            if exact {
                let value = try await driver.fetchExactRowCount(
                    table: table,
                    filters: filters,
                    logicMode: logicMode
                )
                return (value, false)
            }
            if !filters.isEmpty {
                let value = try await driver.fetchFilteredRowCount(
                    table: table,
                    filters: filters,
                    logicMode: logicMode
                )
                return (value, false)
            }
            let value = try await driver.fetchApproximateRowCount(table: table)
            return (value, true)
        }

        guard let count = outcome.count else {
            throw MCPDataLayerError.dataSourceError(
                String(localized: "This engine cannot count rows for that table.")
            )
        }
        return .object([
            "table": .string(table),
            "row_count": .int(count),
            "is_approximate": .bool(outcome.isApproximate),
            "filter_count": .int(filters.count)
        ])
    }

    func browseTable(
        scope: DatabaseScope,
        request: MCPBrowseRequest,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?
    ) async throws -> JsonValue {
        let databaseType = try await ensureConnected(scope.connectionId)
        let schema = scope.schema
        let dialect = try? resolveSQLDialect(for: databaseType)

        let sql = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver -> String in
            let columnInfos = try await driver.fetchColumns(table: request.table, schema: schema)
            guard !columnInfos.isEmpty else {
                throw MCPDataLayerError.notFound(
                    String(localized: "That table has no readable columns.")
                )
            }
            let names = columnInfos.map(\.name)
            let classifier = ColumnTypeClassifier()
            let types = columnInfos.map { classifier.classify(rawTypeName: $0.dataType) }
            let builder = TableQueryBuilder(
                databaseType: databaseType,
                pluginDriver: driver.queryBuildingPluginDriver,
                dialect: dialect
            )
            let sortState = MCPConnectionBridge.sortState(from: request.sort, columns: names)
            let selected = try MCPConnectionBridge.validatedSelection(request.columns, available: names)
            guard !request.filters.isEmpty else {
                return builder.buildBaseQuery(
                    tableName: request.table,
                    schemaName: schema,
                    sortState: sortState,
                    columns: names,
                    selectColumns: selected,
                    limit: request.limit,
                    offset: request.offset
                )
            }
            return builder.buildFilteredQuery(
                tableName: request.table,
                schemaName: schema,
                filters: request.filters,
                logicMode: request.logicMode,
                sortState: sortState,
                columns: names,
                columnTypes: types,
                selectColumns: selected,
                limit: request.limit,
                offset: request.offset
            )
        }

        var payload = try await executeQuery(
            scope: scope,
            query: sql,
            maxRows: request.limit,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation
        )
        if case .object(var fields) = payload {
            fields["table"] = .string(request.table)
            fields["offset"] = .int(request.offset)
            fields["limit"] = .int(request.limit)
            payload = .object(fields)
        }
        return payload
    }

    func searchSchema(scope: DatabaseScope, term: String, limit: Int) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let schema = scope.schema
        let needle = term.lowercased()

        let matches = try await DatabaseManager.shared.withMetadataDriver(
            scope: scope,
            workload: .bulk
        ) { driver -> [JsonValue] in
            let tables = MCPConnectionBridge.sortedTables(try await driver.fetchTables(schema: schema))
            var found: [JsonValue] = []
            for table in tables where table.name.lowercased().contains(needle) {
                found.append(.object([
                    "kind": .string("table"),
                    "name": .string(table.name),
                    "object_type": .string(table.type.rawValue),
                    "schema": table.schema.map(JsonValue.string) ?? JsonValue.null
                ]))
                if found.count >= limit { return found }
            }
            let allColumns = (try? await driver.fetchAllColumns()) ?? [:]
            for tableName in allColumns.keys.sorted() {
                for column in allColumns[tableName] ?? [] where column.name.lowercased().contains(needle) {
                    found.append(.object([
                        "kind": .string("column"),
                        "name": .string(column.name),
                        "table": .string(tableName),
                        "data_type": .string(column.dataType)
                    ]))
                    if found.count >= limit { return found }
                }
            }
            return found
        }
        return .object([
            "term": .string(term),
            "matches": .array(matches),
            "is_truncated": .bool(matches.count >= limit)
        ])
    }

    func insertRows(
        scope: DatabaseScope,
        table: String,
        columns: [String],
        rows: [[JsonValue]],
        cancellation: MCPCancellationToken?
    ) async throws -> JsonValue {
        let databaseType = try await ensureConnected(scope.connectionId)
        let style = await MainActor.run {
            PluginMetadataRegistry.shared.snapshot(for: databaseType)?.parameterStyle
                ?? ParameterStyle.questionMark
        }
        let connectionId = scope.connectionId

        if let cancellation {
            await cancellation.onCancel { _ in
                await MainActor.run {
                    try? DatabaseManager.shared.cancelRunningQuery(for: connectionId, reach: .userStop)
                }
            }
        }

        let route = await MainActor.run { DatabaseManager.shared.executionRoute(for: scope) }
        let schema = scope.schema
        let inserted = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: route,
            cancellation: .protectedWrite
        ) { driver -> Int in
            let quotedTable = MCPConnectionBridge.qualified(table, schema: schema, driver: driver)
            let quotedColumns = columns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
            var affected = 0
            for row in rows {
                let placeholders = MCPConnectionBridge.placeholders(count: row.count, style: style)
                let sql = "INSERT INTO \(quotedTable) (\(quotedColumns)) VALUES (\(placeholders))"
                let result = try await driver.executeParameterized(
                    query: sql,
                    parameters: row.map(MCPConnectionBridge.parameterValue)
                )
                affected += max(result.rowsAffected, 0)
            }
            return affected
        }

        return .object([
            "table": .string(table),
            "rows_submitted": .int(rows.count),
            "rows_affected": .int(inserted)
        ])
    }

    static func qualified(_ table: String, schema: String?, driver: DatabaseDriver) -> String {
        guard let schema, !schema.isEmpty else { return driver.quoteIdentifier(table) }
        return "\(driver.quoteIdentifier(schema)).\(driver.quoteIdentifier(table))"
    }

    static func placeholders(count: Int, style: ParameterStyle) -> String {
        switch style {
        case .dollar:
            return (1...max(count, 1)).map { "$\($0)" }.joined(separator: ", ")
        case .questionMark:
            return Array(repeating: "?", count: max(count, 1)).joined(separator: ", ")
        }
    }

    static func parameterValue(_ value: JsonValue) -> Any? {
        switch value {
        case .null: return nil
        case .bool(let flag): return flag
        case .int(let number): return number
        case .double(let number): return number
        case .string(let text): return text
        case .array, .object: return value.jsonString()
        }
    }

    static func sortState(from sort: [(column: String, descending: Bool)], columns: [String]) -> SortState? {
        let resolved: [SortColumn] = sort.compactMap { entry in
            guard let index = columns.firstIndex(of: entry.column) else { return nil }
            return SortColumn(
                columnIndex: index,
                direction: entry.descending ? .descending : .ascending,
                columnName: entry.column
            )
        }
        guard !resolved.isEmpty else { return nil }
        return SortState(columns: resolved)
    }

    static func validatedSelection(_ requested: [String]?, available: [String]) throws -> [String]? {
        guard let requested, !requested.isEmpty else { return nil }
        let known = Set(available)
        let unknown = requested.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw MCPDataLayerError.invalidArgument(
                String(
                    format: String(localized: "Unknown column(s): %@"),
                    unknown.joined(separator: ", ")
                )
            )
        }
        return requested
    }
}

extension MCPConnectionBridge {
    func explainQuery(
        scope: DatabaseScope,
        sql: String,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?
    ) async throws -> JsonValue {
        let databaseType = try await ensureConnected(scope.connectionId)
        let outcome = try await runStatement(
            scope: scope,
            query: sql,
            maxRows: 5_000,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation
        )
        let routed = ExplainResultRouter.route(
            sql: sql,
            columns: outcome.result.columns,
            rows: outcome.result.rows,
            databaseType: databaseType,
            declaredVariants: databaseType.explainVariants
        )

        var payload: [String: JsonValue] = [
            "statement": .string(sql),
            "execution_time_ms": .double(outcome.executionTimeMs),
            "columns": .array(outcome.result.columns.map { .string($0) }),
            "rows": .array(outcome.result.rows.map { row in .array(row.map(Self.cellValue)) })
        ]
        if let routed {
            payload["plan_text"] = .string(routed.rawText)
            if let plan = routed.plan {
                payload["plan"] = Self.encode(plan: plan)
            }
        }
        return .object(payload)
    }

    static func explainStatement(
        for query: String,
        databaseType: DatabaseType,
        variantId: String?,
        analyze: Bool
    ) throws -> String {
        let variants = databaseType.explainVariants
        let prefix: String
        if let variantId {
            guard let variant = variants.first(where: { $0.id == variantId }) else {
                throw MCPDataLayerError.invalidArgument(
                    String(
                        format: String(localized: "Unknown explain variant '%@'."),
                        variantId
                    )
                )
            }
            prefix = variant.sqlPrefix
        } else if analyze, let variant = variants.first(where: { $0.sqlPrefix.uppercased().contains("ANALYZE") }) {
            prefix = variant.sqlPrefix
        } else if let variant = variants.first {
            prefix = variant.sqlPrefix
        } else {
            prefix = analyze ? "EXPLAIN ANALYZE" : "EXPLAIN"
        }
        let trimmed = stripTrailingSemicolons(query)
        guard !trimmed.isEmpty else {
            throw MCPDataLayerError.invalidArgument(String(localized: "The query is empty."))
        }
        guard !QueryClassifier.isExplainStatement(trimmed) else { return trimmed }
        return "\(prefix) \(trimmed)"
    }

    static func explainVariants(for databaseType: DatabaseType) -> JsonValue {
        .array(databaseType.explainVariants.map { variant in
            .object([
                "id": .string(variant.id),
                "label": .string(variant.label),
                "sql_prefix": .string(variant.sqlPrefix)
            ])
        })
    }

    static func encode(plan: QueryPlan) -> JsonValue {
        var fields: [String: JsonValue] = ["root": encode(node: plan.rootNode)]
        if let planningTime = plan.planningTime {
            fields["planning_time_ms"] = .double(planningTime)
        }
        if let executionTime = plan.executionTime {
            fields["execution_time_ms"] = .double(executionTime)
        }
        return .object(fields)
    }

    static func encode(node: QueryPlanNode) -> JsonValue {
        var fields: [String: JsonValue] = ["operation": .string(node.operation)]
        if let relation = node.relation { fields["relation"] = .string(relation) }
        if let schema = node.schema { fields["schema"] = .string(schema) }
        if let alias = node.alias { fields["alias"] = .string(alias) }
        if let value = node.estimatedStartupCost { fields["estimated_startup_cost"] = .double(value) }
        if let value = node.estimatedTotalCost { fields["estimated_total_cost"] = .double(value) }
        if let value = node.estimatedRows { fields["estimated_rows"] = .int(value) }
        if let value = node.estimatedWidth { fields["estimated_width"] = .int(value) }
        if let value = node.actualStartupTime { fields["actual_startup_time_ms"] = .double(value) }
        if let value = node.actualTotalTime { fields["actual_total_time_ms"] = .double(value) }
        if let value = node.actualRows { fields["actual_rows"] = .int(value) }
        if let value = node.actualLoops { fields["actual_loops"] = .int(value) }
        if !node.properties.isEmpty {
            var properties: [String: JsonValue] = [:]
            for key in node.properties.keys.sorted() {
                properties[key] = .string(node.properties[key] ?? "")
            }
            fields["properties"] = .object(properties)
        }
        if !node.children.isEmpty {
            fields["children"] = .array(node.children.map(encode(node:)))
        }
        return .object(fields)
    }
}
