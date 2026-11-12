import Foundation
import TableProMCP
import TableProSQLGrammar

public struct ExplainQueryTool: MCPToolImplementation {
    public static let name = "explain_query"
    public static let title: String? = String(localized: "Explain Query")
    public static let description = String(
        localized: """
        Ask the engine for the plan of a statement and return both the raw plan text and, where TablePro \
        can parse it, a node tree with costs and row estimates. Setting 'analyze' runs the statement for \
        real, so an analyzed write needs tools:write and Safe Mode approval.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Explain Query"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "query": MCPToolSchema.string(String(localized: "The statement to explain, without an EXPLAIN prefix")),
            "analyze": MCPToolSchema.boolean(
                String(localized: "Run the statement and report actual timings (default false)")
            ),
            "variant": MCPToolSchema.string(
                String(localized: "Explain variant id for this engine. Call with no variant to see the list.")
            ),
            "timeout_seconds": MCPToolSchema.integer(
                String(localized: "Statement timeout. Defaults to the server's configured timeout."),
                minimum: 1
            ),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "query"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "statement": MCPToolSchema.string(
                String(localized: "The statement that was sent, with its prefix, or alone when the driver builds the plan")
            ),
            "execution_time_ms": MCPToolSchema.number(String(localized: "Round trip in milliseconds")),
            "columns": MCPToolSchema.array(String(localized: "Raw result columns"), of: MCPToolSchema.stringItem),
            "rows": MCPToolSchema.array(
                String(localized: "Raw result rows"),
                of: .object(["type": .string("array"), "items": MCPToolSchema.cell])
            ),
            "plan_text": MCPToolSchema.string(String(localized: "Flattened plan text")),
            "status_message": MCPToolSchema.string(String(localized: "Why values are masked, when they are")),
            "plan": MCPToolSchema.object(
                properties: [
                    "root": MCPToolSchema.anyValue,
                    "planning_time_ms": MCPToolSchema.number(String(localized: "Planning time")),
                    "execution_time_ms": MCPToolSchema.number(String(localized: "Execution time"))
                ],
                required: ["root"],
                allowsAdditional: true
            ),
            "available_variants": MCPToolSchema.array(
                String(localized: "Explain variants this engine declares"),
                of: MCPToolSchema.object(
                    properties: [
                        "id": MCPToolSchema.string(String(localized: "Variant id")),
                        "label": MCPToolSchema.string(String(localized: "Human label")),
                        "sql_prefix": MCPToolSchema.string(String(localized: "Prefix the variant applies")),
                        "runs_statement": MCPToolSchema.boolean(
                            String(localized: "Whether the variant runs the statement to measure it")
                        )
                    ],
                    required: ["id", "label", "sql_prefix", "runs_statement"]
                )
            )
        ],
        required: ["statement", "execution_time_ms", "columns", "rows"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: MCPScopeArguments.keys.union(["query", "analyze", "variant", "timeout_seconds"])
        )
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let query = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "query")
        let analyze = try MCPArgumentDecoder.optionalBool(arguments, key: "analyze", default: false)
        let variant = try MCPArgumentDecoder.optionalString(arguments, key: "variant")

        let settings = await services.settingsProvider()
        let timeoutSeconds = try MCPLimitResolver.resolveTimeoutSeconds(arguments, settings: settings)
        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)

        // A registry plugin loads on first use, and its explain variants register with it.
        await MainActor.run { _ = PluginManager.shared.driverPlugin(for: meta.databaseType) }

        let request: MCPExplainRequest
        do {
            request = try MCPConnectionBridge.explainRequest(
                for: query,
                databaseType: meta.databaseType,
                variantId: variant,
                analyze: analyze
            )
        } catch let error as DatabaseAccessError {
            throw MCPToolExecutionError.from(error, secrets: meta.redactionSecrets)
        }

        let classification = try MCPStatementGate.classify(
            sql: request.gatedSQL,
            meta: meta,
            allowsDestructive: false,
            destructiveAlternative: String(
                localized: "This plan runs the statement. Explain it without analyze, with a variant that only plans it."
            ),
            context: context
        )

        let scope = try await MCPScopeArguments.resolve(
            arguments,
            connectionId: connectionId,
            services: services
        )

        let operation: ApprovedOperation
        if request.driverStep != nil {
            // The driver plans the statement itself, so the approval shows what it is asked to plan.
            operation = try await MCPStatementGate.approve(
                [OperationStatement(sql: request.subjectSQL)],
                kind: OperationKind.from(classification.tier),
                gradedSQL: request.gatedSQL,
                displayStatements: [request.gatedSQL],
                scope: scope,
                meta: meta,
                allowsDestructive: false,
                operationLabel: String(localized: "an explain"),
                context: context,
                services: services
            )
        } else {
            let statement: OperationStatement
            do {
                statement = try await services.connectionBridge.plannedStatement(
                    scope: scope,
                    query: request.statement,
                    maxRows: MCPConnectionBridge.explainRowLimit
                )
            } catch {
                throw ToolQueryExecutor.translate(error, secrets: meta.redactionSecrets)
            }
            operation = try await MCPStatementGate.approve(
                [statement],
                kind: OperationKind.from(classification.tier),
                scope: scope,
                meta: meta,
                allowsDestructive: false,
                operationLabel: String(localized: "an explain"),
                context: context,
                services: services
            )
        }

        do {
            var payload = try await services.connectionBridge.explainQuery(
                operation,
                request: request,
                timeoutSeconds: timeoutSeconds,
                cancellation: context.cancellation
            )
            if case .object(var fields) = payload {
                fields["available_variants"] = MCPConnectionBridge.explainVariants(for: meta.databaseType)
                payload = .object(fields)
            }
            return .structured(payload)
        } catch {
            throw ToolQueryExecutor.translate(error, secrets: meta.redactionSecrets)
        }
    }
}
