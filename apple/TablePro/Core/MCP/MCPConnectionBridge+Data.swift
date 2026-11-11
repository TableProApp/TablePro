import Foundation
import TableProMCP
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

    // The SELECT a browse runs, built on the metadata driver before anyone approves it, and the rows it may return.
    func browseStatement(scope: DatabaseScope, request: MCPBrowseRequest) async throws -> (statement: OperationStatement, limit: Int) {
        let databaseType = try await ensureConnected(scope.connectionId)
        let schema = scope.schema
        let dialect = try? resolveSQLDialect(for: databaseType)
        let pagination = await MainActor.run { PluginManager.shared.paginationCapability(for: databaseType) }
        let limit = try MCPConnectionBridge.browseLimit(for: request, pagination: pagination)

        let sql = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver -> String in
            let columnInfos = try await driver.fetchColumns(table: request.table, schema: schema)
            guard !columnInfos.isEmpty else {
                throw DatabaseAccessError.notFound(
                    String(localized: "That table has no readable columns.")
                )
            }
            let names = columnInfos.map(\.name)
            let classifier = ColumnTypeClassifier(family: SQLTypeFamily.of(databaseType))
            let types = columnInfos.map { classifier.classify(rawTypeName: $0.typeNameForClassification) }
            let builder = TableQueryBuilder(
                databaseType: databaseType,
                pluginDriver: driver.queryBuildingPluginDriver,
                dialect: dialect,
                pagination: pagination,
                dialectQuote: dialect.map { quoteIdentifierFromDialect($0, databaseType: databaseType) } ?? { SQLEscaping.quoteIdentifier($0) },
                sessionDriver: driver
            )
            let sortState = try MCPConnectionBridge.sortState(from: request.sort, columns: names)
            let requested = try MCPConnectionBridge.validatedSelection(request.columns, available: names)
            let sortColumnNames = sortState?.columns.compactMap(\.columnName) ?? []
            // A projection that leaves out the sorted column drops the sort with it, so the missing sort columns are
            // appended: every column the caller asked for keeps its position in the positional rows.
            let selected = requested.map { projection in
                projection + sortColumnNames.filter { !projection.contains($0) && names.contains($0) }
            }
            guard !request.filters.isEmpty else {
                return builder.buildBaseQuery(
                    tableName: request.table,
                    schemaName: schema,
                    sortState: sortState,
                    columns: names,
                    selectColumns: selected,
                    limit: limit,
                    offset: request.offset
                )
            }
            guard let query = builder.buildFilteredQuery(
                tableName: request.table,
                schemaName: schema,
                filters: request.filters,
                logicMode: request.logicMode,
                sortState: sortState,
                columns: names,
                columnTypes: types,
                selectColumns: selected,
                limit: limit,
                offset: request.offset
            ) else {
                throw DatabaseAccessError.dataSourceError(
                    String(localized: "This engine cannot filter that table with those conditions.")
                )
            }
            return query
        }
        return (try await plannedStatement(scope: scope, query: sql, maxRows: limit), limit)
    }

    func browseTable(
        _ operation: ApprovedOperation,
        request: MCPBrowseRequest,
        limit: Int,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?
    ) async throws -> JsonValue {
        var payload = try await executeQuery(
            operation,
            maxRows: limit,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation,
            masking: .table(request.table)
        )
        if case .object(var fields) = payload {
            fields["table"] = .string(request.table)
            fields["offset"] = .int(request.offset)
            fields["limit"] = .int(limit)
            if limit < request.limit, case .int(let rowCount)? = fields["row_count"], rowCount >= limit {
                fields["is_truncated"] = .bool(true)
            }
            payload = .object(fields)
        }
        return payload
    }

    /// The row count a browse may ask for. An engine that cannot skip rows serves only the leading
    /// ones, so an offset is refused rather than quietly answered with the first page again, and a
    /// limit past the engine's ceiling is lowered to it.
    static func browseLimit(for request: MCPBrowseRequest, pagination: PaginationCapability) throws -> Int {
        guard pagination.allowsSeeking || request.offset == 0 else {
            throw DatabaseAccessError.invalidArgument(
                String(localized: "This database cannot skip rows, so offset must be 0. Narrow the rows with filters or a sort instead.")
            )
        }
        return pagination.clampedRowCount(request.limit)
    }

    func searchSchema(scope: DatabaseScope, term: String, limit: Int, schemaIsNamed: Bool) async throws -> JsonValue {
        let databaseType = try await ensureConnected(scope.connectionId)
        let tableReach = await MainActor.run {
            MCPSchemaSearch.tableReach(
                schemaIsNamed: schemaIsNamed,
                grouping: PluginManager.shared.databaseGroupingStrategy(for: databaseType),
                systemSchemas: Set(PluginManager.shared.systemSchemaNames(for: databaseType))
            )
        }
        let result = try await MCPSchemaSearch.run(
            MCPSchemaSearch.Request(scope: scope, term: term, limit: limit, tableReach: tableReach),
            metadata: DatabaseManager.shared
        )
        return Self.encode(search: result, term: term, scope: scope, schemaIsNamed: schemaIsNamed)
    }

    static func encode(
        search result: MCPSchemaSearch.Result,
        term: String,
        scope: DatabaseScope,
        schemaIsNamed: Bool
    ) -> JsonValue {
        var payload: [String: JsonValue] = [
            "term": .string(term),
            "database": .string(scope.database),
            "schema": schemaIsNamed ? nullable(scope.schema) : .null,
            "matches": .array(result.matches.map(encode(match:))),
            "is_truncated": .bool(result.isTruncated),
            "unlisted_schemas": .array(result.unlistedSchemas.map(JsonValue.string)),
            "column_search": .string(result.columnSearch.outcome.rawValue)
        ]
        if case .searched(let schema) = result.columnSearch {
            payload["columns_schema"] = nullable(schema)
        }
        return .object(payload)
    }

    static func encode(match: MCPSchemaSearch.Match) -> JsonValue {
        switch match {
        case .table(let name, let schema, let type):
            return .object([
                "kind": .string("table"),
                "name": .string(name),
                "schema": nullable(schema),
                "object_type": .string(type.rawValue)
            ])
        case .column(let name, let table, let schema, let dataType):
            return .object([
                "kind": .string("column"),
                "name": .string(name),
                "table": .string(table),
                "schema": nullable(schema),
                "data_type": .string(dataType)
            ])
        }
    }

    private static func nullable(_ value: String?) -> JsonValue {
        value.map(JsonValue.string) ?? .null
    }

    // One INSERT per row in the engine's quoting and placeholder style, each with its values, before any approval.
    func insertStatements(
        scope: DatabaseScope,
        table: String,
        columns: [String],
        rows: [[JsonValue]]
    ) async throws -> [OperationStatement] {
        let (driver, databaseType) = try await resolveDriver(scope.connectionId)
        let style = await MainActor.run {
            PluginMetadataRegistry.shared.snapshot(for: databaseType)?.parameterStyle
                ?? ParameterStyle.questionMark
        }
        let quotedTable = MCPConnectionBridge.qualified(table, schema: scope.schema, driver: driver)
        let quotedColumns = columns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
        return rows.map { row in
            OperationStatement(
                sql: "INSERT INTO \(quotedTable) (\(quotedColumns)) VALUES (\(MCPConnectionBridge.placeholders(count: row.count, style: style)))",
                parameters: row.map { PluginDriverAdapter.cellValue(for: MCPConnectionBridge.parameterValue($0)) }
            )
        }
    }

    static func qualified(_ table: String, schema: String?, driver: DatabaseDriver) -> String {
        SchemaQualifiedName.render(
            name: table,
            schema: schema,
            databaseType: driver.connection.type,
            quote: driver.quoteIdentifier
        )
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

    static func sortState(from sort: [(column: String, descending: Bool)], columns: [String]) throws -> SortState? {
        try rejectUnknownColumns(sort.map(\.column), available: columns)
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
        try rejectUnknownColumns(requested, available: available)
        return requested
    }

    private static func rejectUnknownColumns(_ requested: [String], available: [String]) throws {
        let known = Set(available)
        let unknown = Set(requested.filter { !known.contains($0) }).sorted()
        guard unknown.isEmpty else {
            throw DatabaseAccessError.invalidArgument(
                String(
                    format: String(localized: "Unknown column(s): %@"),
                    unknown.joined(separator: ", ")
                )
            )
        }
    }
}

struct MCPExplainRequest: Equatable {
    let statement: String
    let gatedSQL: String

    let subjectSQL: String
    let driverStep: ExplainRequest.DriverStep?
    // The plan's shape: the variant's, or for a statement the caller wrote as EXPLAIN, the engine's first variant's.
    var format: ExplainPlanFormat?
}

extension MCPConnectionBridge {
    // The router reads the whole plan, so the budget holds only what goes out: the plan text, the parsed plan, the rows.
    func explainQuery(
        _ operation: ApprovedOperation,
        request: MCPExplainRequest,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?,
        budget: ExternalAnswerBudget = .mcpAnswer
    ) async throws -> JsonValue {
        let databaseType = operation.databaseType
        let masking = ExternalRowMasking.plan(in: request.format)
        let outcome: (result: QueryResult, executionTimeMs: Double)
        let routed: ExplainResultRouter.RoutedPlan?
        if let step = request.driverStep {
            outcome = try await runExplainPlan(
                operation,
                step: step,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation,
                masking: masking
            )
            routed = ExplainResultRouter.routeDriverPlan(
                rows: outcome.result.rows,
                subjectSQL: request.subjectSQL,
                variantId: step.variantId,
                databaseType: databaseType,
                declaredVariants: databaseType.explainVariants
            )
        } else {
            let statement = try await runStatement(
                operation,
                maxRows: Self.explainRowLimit,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation,
                masking: masking,
                budget: nil
            )
            outcome = (statement.result, statement.executionTimeMs)
            routed = ExplainResultRouter.route(
                sql: request.statement,
                columns: outcome.result.columns,
                rows: outcome.result.rows,
                databaseType: databaseType,
                declaredVariants: databaseType.explainVariants
            )
        }

        var spent = budget
        let planText = routed.map { spent.keep(text: $0.rawText) }
        // The tree repeats every node's text, so it goes out only when it fits whole; plan_text already carries it.
        let encodedPlan = routed?.plan.map(Self.encode(plan:))
        let plan = encodedPlan.flatMap { spent.keepWhole(bytes: Self.encodedBytes(of: $0)) ? $0 : nil }
        let planLeftOut = encodedPlan != nil && plan == nil
        let kept = spent.keep(outcome.result)
        var payload: [String: JsonValue] = [
            "statement": .string(request.statement),
            "execution_time_ms": .double(outcome.executionTimeMs),
            "columns": .array(outcome.result.columns.map { .string($0) }),
            "rows": .array(kept.rows.map { row in .array(row.map(Self.cellValue)) })
        ]
        if let statusMessage = outcome.result.statusMessage {
            payload["status_message"] = .string(statusMessage)
        }
        if let planText {
            payload["plan_text"] = .string(planText)
        }
        if let plan {
            payload["plan"] = plan
        }
        if spent.sizeLimited || planLeftOut {
            payload["is_truncated"] = .bool(true)
        }
        var notes = spent.notes
        if planLeftOut {
            notes.append(String(
                format: String(localized: "The parsed plan did not fit in TablePro's %@ limit for one answer, so it is left out. Read plan_text instead."),
                ByteCountFormatter.string(fromByteCount: Int64(spent.limitBytes), countStyle: .memory)
            ))
        }
        if !notes.isEmpty {
            payload["notes"] = .array(notes.map(JsonValue.string))
        }
        return .object(payload)
    }

    // What `value` encodes to, measured without rendering it; a number counts as the core counts a scalar.
    static func encodedBytes(of value: JsonValue) -> Int {
        switch value {
        case .null: return 4
        case .bool: return 5
        case .int, .double: return 40
        case .string(let text): return text.utf8.count + 2
        case .array(let items): return items.reduce(2) { $0 + encodedBytes(of: $1) + 1 }
        case .object(let fields): return fields.reduce(2) { $0 + $1.key.utf8.count + 3 + encodedBytes(of: $1.value) + 1 }
        }
    }

    static let explainRowLimit = 5_000

    static func explainStatement(
        for query: String,
        databaseType: DatabaseType,
        variantId: String?,
        analyze: Bool
    ) throws -> String {
        try explainRequest(for: query, databaseType: databaseType, variantId: variantId, analyze: analyze).statement
    }

    static func explainRequest(
        for query: String,
        databaseType: DatabaseType,
        variantId: String?,
        analyze: Bool
    ) throws -> MCPExplainRequest {
        try explainRequest(
            for: query,
            databaseType: databaseType,
            variants: databaseType.explainVariants,
            variantId: variantId,
            analyze: analyze
        )
    }

    static func explainRequest(
        for query: String,
        databaseType: DatabaseType,
        variants: [ExplainVariant],
        variantId: String?,
        analyze: Bool
    ) throws -> MCPExplainRequest {
        let trimmed = statementText(query, databaseType: databaseType)
        guard !trimmed.isEmpty else {
            throw DatabaseAccessError.invalidArgument(String(localized: "The query is empty."))
        }
        guard !QueryClassifier.isExplainStatement(trimmed, grammar: databaseType.lexicalGrammar) else {
            return MCPExplainRequest(
                statement: trimmed, gatedSQL: trimmed, subjectSQL: trimmed, driverStep: nil, format: variants.first?.format
            )
        }
        guard let first = variants.first else {
            throw DatabaseAccessError.invalidArgument(String(localized: "This database does not explain statements."))
        }
        let variant = try explainVariant(id: variantId, analyze: analyze, in: variants, first: first)
        switch variant.step {
        case .sqlPrefix:
            let prefixed = "\(variant.sqlPrefix) \(trimmed)"
            return MCPExplainRequest(
                statement: prefixed, gatedSQL: prefixed, subjectSQL: trimmed, driverStep: nil, format: variant.format
            )
        case .driver(let runsStatement):
            return MCPExplainRequest(
                statement: trimmed,
                gatedSQL: ExplainRequest.gatedSQL(
                    subject: trimmed, runsStatement: runsStatement, databaseType: databaseType
                ),
                subjectSQL: trimmed,
                driverStep: ExplainRequest.DriverStep(variantId: variant.id, runsStatement: runsStatement),
                format: variant.format
            )
        @unknown default:
            throw DatabaseAccessError.invalidArgument(
                String(format: String(localized: "Unknown explain variant '%@'. This database offers: %@."),
                       variant.id, variants.map(\.id).joined(separator: ", "))
            )
        }
    }

    private static func runsStatement(_ variant: ExplainVariant) -> Bool {
        switch variant.step {
        case .sqlPrefix:
            return variant.sqlPrefix.uppercased().contains("ANALYZE")
        case .driver(let runsStatement):
            return runsStatement
        @unknown default:
            return false
        }
    }

    private static func explainVariant(
        id: String?,
        analyze: Bool,
        in variants: [ExplainVariant],
        first: ExplainVariant
    ) throws -> ExplainVariant {
        let offered = variants.map(\.id).joined(separator: ", ")
        let running = variants.filter(runsStatement)
        let chosen: ExplainVariant
        if let id {
            guard let variant = variants.first(where: { $0.id == id }) else {
                throw DatabaseAccessError.invalidArgument(
                    String(format: String(localized: "Unknown explain variant '%@'. This database offers: %@."), id, offered)
                )
            }
            chosen = variant
        } else {
            chosen = analyze ? running.first ?? first : first
        }
        guard analyze, !running.contains(where: { $0.id == chosen.id }) else { return chosen }
        guard !running.isEmpty else {
            throw DatabaseAccessError.invalidArgument(
                String(
                    format: String(
                        localized: "This database has no explain variant that runs the statement. Leave 'analyze' off, or pass one of these as 'variant': %@."
                    ),
                    offered
                )
            )
        }
        throw DatabaseAccessError.invalidArgument(
            String(
                format: String(
                    localized: "The '%1$@' variant does not run the statement. Leave 'analyze' off, or pass one that does: %2$@."
                ),
                chosen.id,
                running.map(\.id).joined(separator: ", ")
            )
        )
    }

    static func explainVariants(for databaseType: DatabaseType) -> JsonValue {
        .array(databaseType.explainVariants.map { variant in
            .object([
                "id": .string(variant.id),
                "label": .string(variant.label),
                "sql_prefix": .string(variant.sqlPrefix),
                "runs_statement": .bool(runsStatement(variant))
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
        if !node.warnings.isEmpty {
            fields["warnings"] = .array(node.warnings.map { .string($0) })
        }
        if !node.missingIndexes.isEmpty {
            fields["missing_indexes"] = .array(node.missingIndexes.map { index in
                var entry: [String: JsonValue] = ["create_statement": .string(index.createStatement)]
                if let impact = index.impact { entry["impact_percent"] = .double(impact) }
                return .object(entry)
            })
        }
        if !node.children.isEmpty {
            fields["children"] = .array(node.children.map(encode(node:)))
        }
        return .object(fields)
    }
}
