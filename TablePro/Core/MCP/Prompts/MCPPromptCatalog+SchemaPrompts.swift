import Foundation

extension MCPPromptCatalog {
    static let schemaPrompts: [MCPPromptDefinition] = [
        explainSchema,
        explainTable,
        dataQualityAudit
    ]

    static let audiences = ["newcomer", "analyst", "engineer"]

    private static let inventoryLimit = 200
    private static let detailedTableLimit = 8

    private static var explainSchema: MCPPromptDefinition {
        MCPPromptDefinition(
            name: "explain_schema",
            title: String(localized: "Explain a schema"),
            description: String(
                localized: "Tour the tables of a live database and how they relate, built from the current schema"
            ),
            arguments: [
                .connection,
                .database,
                .schema,
                MCPPromptArgument(
                    name: "audience",
                    title: String(localized: "Audience"),
                    description: String(localized: "Who the explanation is for: newcomer, analyst, or engineer"),
                    completion: .values(audiences)
                )
            ],
            render: { context in
                let audience = try context.choice("audience", allowed: audiences, default: "newcomer")
                let target = try await context.resolveTarget()
                let inventory = try await context.schema.tableInventory(target: target, includeRowCounts: true)
                let details = await context.schema.tableDetails(
                    target: target,
                    tables: largestTableNames(inventory, limit: detailedTableLimit)
                )

                let text = """
                You are looking at a live database through TablePro.

                ## Connection
                \(MCPPromptMarkdown.connectionHeader(target))

                ## Tables
                \(MCPPromptMarkdown.inventory(inventory, limit: inventoryLimit))

                ## Structure of the \(details.count) largest tables
                \(MCPPromptMarkdown.tableSections(details, includeDdl: false))

                Write a tour of this schema. \(audienceInstruction(audience))

                Cover, in this order:
                1. What this database is for, inferred from the table and column names.
                2. The core entities and how they relate. Name the join keys you would use.
                3. Which tables are lookups, which are transactional, and which look like logs or staging.
                4. Anything that looks wrong: missing primary keys, foreign keys the names imply but the schema \
                does not declare, columns that duplicate data held elsewhere.
                5. Where to start reading if you had to answer a question about this data tomorrow.

                Use only the structure above. When something is not shown, say so and name the table you would \
                inspect next instead of guessing.
                """

                return MCPPromptRendering(
                    description: String(
                        format: String(localized: "Schema tour of %@ on %@"),
                        target.scopeDescription,
                        target.connection.name
                    ),
                    messages: [.user(text)]
                )
            }
        )
    }

    private static var explainTable: MCPPromptDefinition {
        MCPPromptDefinition(
            name: "explain_table",
            title: String(localized: "Explain a table"),
            description: String(
                localized: "Explain one table's columns, keys, indexes, and DDL to someone who has never used it"
            ),
            arguments: [
                .connection,
                .table(description: String(localized: "Table to explain")),
                .database,
                .schema,
                MCPPromptArgument(
                    name: "audience",
                    title: String(localized: "Audience"),
                    description: String(localized: "Who the explanation is for: newcomer, analyst, or engineer"),
                    completion: .values(audiences)
                )
            ],
            render: { context in
                let audience = try context.choice("audience", allowed: audiences, default: "newcomer")
                let table = try context.requiredValue(MCPPromptArgument.tableArgumentName)
                let target = try await context.resolveTarget()
                let detail = try await context.schema.tableDetail(target: target, table: table)

                let text = """
                Explain the table `\(table)` on a live \(target.connection.databaseType) database.

                ## Connection
                \(MCPPromptMarkdown.connectionHeader(target))

                ## Structure
                \(MCPPromptMarkdown.tableSection(detail, includeDdl: true))

                \(audienceInstruction(audience))

                Cover, in this order:
                1. What one row of this table represents, in one sentence.
                2. Every column that is not self-explanatory: what it holds, its units or likely value set, and \
                what a NULL means there.
                3. How this table connects to the rest of the schema, using the foreign keys above.
                4. The indexes: which access patterns they serve, and which obvious filter has no index.
                5. Three queries someone would actually run against this table, in \
                \(target.connection.databaseType) syntax.

                Use only the structure above. Do not invent columns.
                """

                return MCPPromptRendering(
                    description: String(
                        format: String(localized: "Explanation of %@ on %@"),
                        table,
                        target.connection.name
                    ),
                    messages: [.user(text)]
                )
            }
        )
    }

    private static var dataQualityAudit: MCPPromptDefinition {
        MCPPromptDefinition(
            name: "data_quality_audit",
            title: String(localized: "Draft a data quality audit"),
            description: String(
                localized: "Turn one table's structure into a runnable checklist of data quality queries"
            ),
            arguments: [
                .connection,
                .table(description: String(localized: "Table to audit")),
                .database,
                .schema
            ],
            render: { context in
                let table = try context.requiredValue(MCPPromptArgument.tableArgumentName)
                let target = try await context.resolveTarget()
                let detail = try await context.schema.tableDetail(target: target, table: table)
                let rowCount = detail.approximateRowCount.map(String.init) ?? "unknown"

                let text = """
                Draft a data quality audit for the table `\(table)`.

                ## Connection
                \(MCPPromptMarkdown.connectionHeader(target))

                ## Structure
                \(MCPPromptMarkdown.tableSection(detail, includeDdl: false))

                Approximate row count: \(rowCount).

                For every check, give three things: what it looks for and why it matters for this column, one \
                runnable \(target.connection.databaseType) query that returns the offending rows or a count of \
                them, and what a clean result looks like.

                Cover at least:
                1. Nullability: the nullable columns whose names imply a value should always be present.
                2. Uniqueness: the primary key, plus any column that reads like a natural key with no unique index.
                3. Referential integrity: each foreign key above checked for orphans, plus columns named like a \
                foreign key that declare no constraint.
                4. Domain: enum-like text columns, negatives where negatives make no sense, dates in the future, \
                timestamps before this system could have existed.
                5. Format: emails, URLs, identifiers, and JSON columns that must parse.
                6. Duplicates: rows that repeat on the business key rather than the surrogate key.

                Order the checks cheapest first. Say which ones need an index to finish at this row count, and \
                which should be sampled instead of run over the whole table.
                """

                return MCPPromptRendering(
                    description: String(
                        format: String(localized: "Data quality audit for %@ on %@"),
                        table,
                        target.connection.name
                    ),
                    messages: [.user(text)]
                )
            }
        )
    }

    private static func audienceInstruction(_ audience: String) -> String {
        switch audience {
        case "analyst":
            "Write it for an analyst who queries this data and needs to know where the numbers live."
        case "engineer":
            "Write it for an engineer who is about to change this schema."
        default:
            "Write it for a developer who has never seen this database before."
        }
    }

    private static func largestTableNames(_ inventory: [MCPPromptTableEntry], limit: Int) -> [String] {
        inventory
            .sorted { left, right in
                let leftRows = left.rowCount ?? -1
                let rightRows = right.rowCount ?? -1
                if leftRows != rightRows { return leftRows > rightRows }
                return left.name < right.name
            }
            .prefix(limit)
            .map(\.name)
    }
}
