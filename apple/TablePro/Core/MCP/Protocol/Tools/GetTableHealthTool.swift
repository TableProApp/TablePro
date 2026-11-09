import Foundation
import TableProMCP

public struct GetTableHealthTool: MCPToolImplementation {
    public static let name = "get_table_health"
    public static let title: String? = String(localized: "Get Table Health")
    public static let description = String(
        localized: """
        Run TablePro's Table Health checks on one database and return each check's outcome and every finding, \
        with its metrics and the SQL that fixes it. Status comes from the history the Table Health tab records: \
        new since its last run, or ignored by the user. This call records nothing and runs no fix. Available on \
        every engine that has Table Health in TablePro.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Get Table Health"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    static let outcomes = ["completed", "skipped", "failed"]
    static let statuses = ["new", "ignored", "none"]
    static let metricTypes = ["count", "bytes", "percent", "date", "text", "flag"]

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "database": MCPToolSchema.database
        ],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "database": MCPToolSchema.string(String(localized: "Database the checks ran on")),
            "generated_at": MCPToolSchema.string(String(localized: "ISO 8601 time the checks ran")),
            "notes": MCPToolSchema.array(
                String(localized: "Notes on the whole report, such as when the usage counters started"),
                of: MCPToolSchema.stringItem
            ),
            "checks": MCPToolSchema.array(
                String(localized: "Every check this engine runs, in order"),
                of: MCPToolSchema.object(
                    properties: [
                        "kind": MCPToolSchema.string(String(localized: "Check id, also set on each of its findings")),
                        "title": MCPToolSchema.string(String(localized: "Check name")),
                        "summary": MCPToolSchema.string(String(localized: "What the check looks for, with its threshold")),
                        "outcome": MCPToolSchema.string(
                            String(localized: "Whether the check ran"),
                            enumValues: outcomes
                        ),
                        "reason": MCPToolSchema.string(String(localized: "Why the check was skipped or failed")),
                        "note": MCPToolSchema.string(String(localized: "What to know when reading this check's findings")),
                        "finding_count": MCPToolSchema.integer(String(localized: "Findings the check reported"))
                    ],
                    required: ["kind", "title", "summary", "outcome", "finding_count"]
                )
            ),
            "findings": MCPToolSchema.array(
                String(localized: "Findings of every check that completed, ignored ones included"),
                of: MCPToolSchema.object(
                    properties: [
                        "kind": MCPToolSchema.string(String(localized: "Id of the check that reported it")),
                        "schema": MCPToolSchema.string(String(localized: "Schema, on engines that have one")),
                        "table": MCPToolSchema.string(String(localized: "Table the finding is about")),
                        "object": MCPToolSchema.string(
                            String(localized: "Index, constraint, sequence or column the finding is about")
                        ),
                        "detail": MCPToolSchema.string(String(localized: "One-line description")),
                        "size_bytes": MCPToolSchema.integer(
                            String(localized: "On-disk size of what the fix acts on: the index for an index check, the table otherwise")
                        ),
                        "metrics": MCPToolSchema.array(
                            String(localized: "Measured values"),
                            of: MCPToolSchema.object(
                                properties: [
                                    "id": MCPToolSchema.string(String(localized: "Stable metric id")),
                                    "label": MCPToolSchema.string(String(localized: "Metric name")),
                                    "type": MCPToolSchema.string(
                                        String(localized: "How to read value: percent is a fraction (0.25 means 25 percent), date is ISO 8601"),
                                        enumValues: metricTypes
                                    ),
                                    "value": .object([
                                        "description": .string(
                                            String(localized: "Number, string, boolean or null, as type says")
                                        )
                                    ])
                                ],
                                required: ["id", "label", "type", "value"]
                            )
                        ),
                        "fix_sql": MCPToolSchema.string(
                            String(localized: "SQL that fixes the finding, absent when there is none. Review it before running it.")
                        ),
                        "status": MCPToolSchema.string(
                            String(localized: "new: not seen in the last run the Table Health tab recorded; ignored: the user accepted it"),
                            enumValues: statuses
                        )
                    ],
                    required: ["kind", "detail", "metrics", "status"]
                )
            )
        ],
        required: ["database", "generated_at", "notes", "checks", "findings"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "database"])
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.tableHealth(scope: scope)
        return .structured(payload)
    }
}
