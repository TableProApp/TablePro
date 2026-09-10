import Foundation

extension MCPPromptCatalog {
    static let operationsPrompts: [MCPPromptDefinition] = [
        writeMigration,
        summarizeQueryHistory
    ]

    private static let missingTableNotice = """
    No table was named, so no structure is shown. Ask for the table before writing anything that depends on \
    its columns.
    """

    private static let historyDefaultLimit = 50
    private static let historyLimitRange = 1...500

    private static var writeMigration: MCPPromptDefinition {
        MCPPromptDefinition(
            name: "write_migration",
            title: String(localized: "Write a migration and its rollback"),
            description: String(
                localized: "Turn a described schema change into migration statements plus the rollback, for this engine"
            ),
            arguments: [
                .connection,
                MCPPromptArgument(
                    name: "change",
                    title: String(localized: "Change"),
                    description: String(localized: "The schema change to make, in plain language"),
                    isRequired: true
                ),
                .table(
                    description: String(localized: "Table the change applies to, if it is one table"),
                    isRequired: false
                ),
                .database,
                .schema
            ],
            render: { context in
                let change = try context.requiredValue("change")
                let table = context.value(MCPPromptArgument.tableArgumentName)
                let target = try await context.resolveTarget()
                let details = await context.schema.tableDetails(
                    target: target,
                    tables: table.map { [$0] } ?? []
                )

                let text = """
                Write the migration for this change on \(target.connection.databaseType).

                ## Requested change
                \(change)

                ## Connection
                \(MCPPromptMarkdown.connectionHeader(target))

                ## Current structure
                \(details.isEmpty ? missingTableNotice : MCPPromptMarkdown.tableSections(details, includeDdl: true))

                Deliver, in this order:
                1. The forward migration, as statements in execution order.
                2. The rollback that returns the schema to exactly what is shown above.
                3. What breaks while it runs: the locks each statement takes, whether readers or writers block, \
                and how long that lasts at the row counts shown.
                4. The backfill, if the change needs one, written so it can run in batches without holding a \
                long transaction.
                5. One query to run afterwards that proves the change landed.

                Rules:
                - Write \(target.connection.databaseType) syntax and use that engine's own guards \
                (IF EXISTS, IF NOT EXISTS, CONCURRENTLY) where they exist.
                - Never drop a column or a table in the forward migration when a rename now and a drop later \
                is possible. If you split it into two deploys, say where the boundary is.
                - If the engine cannot do this in one step, say which steps it needs and why.
                - Safe mode on this connection is \(target.connection.safeMode). Flag any statement that a \
                read-only or restricted mode would reject.
                """

                return MCPPromptRendering(
                    description: String(
                        format: String(localized: "Migration plan for %@"),
                        target.connection.name
                    ),
                    messages: [.user(text)]
                )
            }
        )
    }

    private static var summarizeQueryHistory: MCPPromptDefinition {
        MCPPromptDefinition(
            name: "summarize_query_history",
            title: String(localized: "Summarize query history"),
            description: String(
                localized: "Summarize what was run against a connection over a period, from the recorded history"
            ),
            arguments: [
                .connection,
                MCPPromptArgument(
                    name: "period",
                    title: String(localized: "Period"),
                    description: String(localized: "Period to summarize: today, this_week, this_month, or all"),
                    completion: .values(MCPPromptSchemaReader.historyPeriods)
                ),
                MCPPromptArgument(
                    name: "limit",
                    title: String(localized: "Limit"),
                    description: String(localized: "How many statements to include, 1 to 500. Defaults to 50")
                )
            ],
            render: { context in
                let period = try context.choice(
                    "period",
                    allowed: MCPPromptSchemaReader.historyPeriods,
                    default: "this_week"
                )
                let limit = try context.integer("limit", default: historyDefaultLimit, clamp: historyLimitRange)
                let connection = try await context.schema.resolveConnection(
                    reference: context.requiredValue(MCPPromptArgument.connectionArgumentName),
                    principal: context.principal
                )
                let entries = try await context.schema.history(
                    connectionId: connection.id,
                    limit: limit,
                    period: period,
                    principal: context.principal
                )

                let text = """
                Summarize what was run against the \(connection.databaseType) connection \
                "\(connection.name)" during \(period.replacingOccurrences(of: "_", with: " ")).

                ## History (\(entries.count) statements, newest first)
                \(MCPPromptMarkdown.historyTable(entries))

                Cover:
                1. What was being worked on: group the statements by the tables they touch and the intent \
                behind each group.
                2. Writes: every INSERT, UPDATE, DELETE, and DDL statement, and what each one changed.
                3. Failures: what failed, the error, and whether a later statement looks like the fix.
                4. Cost: the slowest statements, what they were scanning, and whether they were repeated.
                5. Loose ends: a migration applied to one table but not its sibling, a query run over and over \
                with no result, a change with no matching verification.

                Use only the statements above. Do not invent tables that never appear in them.
                """

                return MCPPromptRendering(
                    description: String(
                        format: String(localized: "Query history summary for %@"),
                        connection.name
                    ),
                    messages: [.user(text)]
                )
            }
        )
    }
}
