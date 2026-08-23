import Foundation

extension MCPPromptCatalog {
    static let queryPrompts: [MCPPromptDefinition] = [
        questionToSql,
        reviewQuery,
        proposeIndexes
    ]

    private static let referencedTableLimit = 6
    private static let queryInventoryLimit = 150
    private static let queryExcerptLimit = 8_000

    private static var questionToSql: MCPPromptDefinition {
        MCPPromptDefinition(
            name: "question_to_sql",
            title: String(localized: "Turn a question into SQL"),
            description: String(
                localized: "Write a query that answers a question, using the real columns of the named tables"
            ),
            arguments: [
                .connection,
                MCPPromptArgument(
                    name: "question",
                    title: String(localized: "Question"),
                    description: String(localized: "The question to answer, in plain language"),
                    isRequired: true
                ),
                MCPPromptArgument(
                    name: "tables",
                    title: String(localized: "Tables"),
                    description: String(localized: "Comma-separated tables to use. All loaded tables when omitted"),
                    completion: .table
                ),
                .database,
                .schema
            ],
            render: { context in
                let question = try context.requiredValue("question")
                let requested = context.list("tables")
                let target = try await context.resolveTarget()
                let inventory = try await context.schema.tableInventory(target: target, includeRowCounts: true)
                let names = requested.isEmpty
                    ? Array(inventory.prefix(referencedTableLimit).map(\.name))
                    : Array(requested.prefix(referencedTableLimit))
                let details = await context.schema.tableDetails(target: target, tables: names)

                let text = """
                Answer this question with one query against a live \(target.connection.databaseType) database.

                ## Question
                \(question)

                ## Connection
                \(MCPPromptMarkdown.connectionHeader(target))

                ## Tables in scope
                \(MCPPromptMarkdown.inventory(inventory, limit: queryInventoryLimit))

                ## Structure of the tables you can use
                \(MCPPromptMarkdown.tableSections(details, includeDdl: false))

                Rules:
                - Use only the tables and columns shown above. If the question needs something that is not \
                there, say what is missing and stop.
                - Qualify every column when more than one table is involved, and state the join key you used.
                - Prefer explicit JOIN ... ON. Say which joins can multiply rows and how you avoided it.
                - Add a LIMIT unless the answer is an aggregate.
                - Write \(target.connection.databaseType) syntax, with that engine's identifier quoting.

                After the query, give two sentences: what a row of the result means, and the one assumption you \
                had to make about the data.
                """

                return MCPPromptRendering(
                    description: String(
                        format: String(localized: "Query for a question on %@"),
                        target.connection.name
                    ),
                    messages: [.user(text)]
                )
            }
        )
    }

    private static var reviewQuery: MCPPromptDefinition {
        MCPPromptDefinition(
            name: "review_query",
            title: String(localized: "Review a query before it runs"),
            description: String(
                localized: "Check a query for correctness, cost, and risk against the live schema before running it"
            ),
            arguments: [
                .connection,
                MCPPromptArgument(
                    name: "query",
                    title: String(localized: "Query"),
                    description: String(localized: "The query to review"),
                    isRequired: true
                ),
                MCPPromptArgument(
                    name: "explain_plan",
                    title: String(localized: "Explain plan"),
                    description: String(localized: "Output of EXPLAIN for this query, if you have it")
                ),
                .database,
                .schema
            ],
            render: { context in
                let query = try context.requiredValue("query")
                let plan = context.value("explain_plan")
                let target = try await context.resolveTarget()
                let inventory = try await context.schema.tableInventory(target: target, includeRowCounts: true)
                let details = await context.schema.tableDetails(
                    target: target,
                    tables: referencedTables(in: query, inventory: inventory, limit: referencedTableLimit)
                )

                let text = """
                Review this query before it runs against a live \(target.connection.databaseType) database.

                ## Connection
                \(MCPPromptMarkdown.connectionHeader(target))

                ## Query
                \(queryBlock(query))
                \(planSection(plan))

                ## Tables it references
                \(MCPPromptMarkdown.tableSections(details, includeDdl: false))

                Answer in this order:
                1. Correctness: does it return what it looks like it is asking for? Name every join that can \
                duplicate rows, every NULL that changes a comparison or an aggregate, and every filter that \
                silently drops rows.
                2. Cost: which of the indexes above can serve it, what it scans without them, and how much data \
                that is at the row counts shown.
                3. Risk: what it writes or deletes, the locks it takes, whether it is safe inside a transaction, \
                and whether it can be cancelled mid-flight.
                4. A rewrite, only if it needs one, with each change explained.

                If the query is fine as written, say so plainly and stop. Do not invent columns to justify a \
                rewrite.
                """

                return MCPPromptRendering(
                    description: String(
                        format: String(localized: "Query review on %@"),
                        target.connection.name
                    ),
                    messages: [.user(text)]
                )
            }
        )
    }

    private static var proposeIndexes: MCPPromptDefinition {
        MCPPromptDefinition(
            name: "propose_indexes",
            title: String(localized: "Propose indexes for a slow query"),
            description: String(
                localized: "Suggest indexes for a slow query from its plan and the indexes the tables already have"
            ),
            arguments: [
                .connection,
                MCPPromptArgument(
                    name: "query",
                    title: String(localized: "Query"),
                    description: String(localized: "The slow query"),
                    isRequired: true
                ),
                MCPPromptArgument(
                    name: "explain_plan",
                    title: String(localized: "Explain plan"),
                    description: String(localized: "Output of EXPLAIN or EXPLAIN ANALYZE for this query")
                ),
                .database,
                .schema
            ],
            render: { context in
                let query = try context.requiredValue("query")
                let plan = context.value("explain_plan")
                let target = try await context.resolveTarget()
                let inventory = try await context.schema.tableInventory(target: target, includeRowCounts: true)
                let details = await context.schema.tableDetails(
                    target: target,
                    tables: referencedTables(in: query, inventory: inventory, limit: referencedTableLimit)
                )

                let text = """
                Propose indexes for this slow query on \(target.connection.databaseType).

                ## Connection
                \(MCPPromptMarkdown.connectionHeader(target))

                ## Query
                \(queryBlock(query))
                \(planSection(plan))

                ## Tables, their row counts, and the indexes they already have
                \(MCPPromptMarkdown.tableSections(details, includeDdl: false))

                For every candidate index, give:
                - the exact CREATE INDEX statement for this engine
                - the predicate or join it serves, quoted from the query
                - why the existing indexes above do not already serve it
                - what it costs: write amplification, storage at the row counts shown, and whether it duplicates \
                the prefix of an index that already exists

                Then rank the candidates, say which one to create first, and give the exact command to measure \
                the change before and after. Name any existing index this query makes redundant.

                Do not propose an index that differs from an existing one only in column order unless you \
                explain why the order matters here.
                """

                return MCPPromptRendering(
                    description: String(
                        format: String(localized: "Index proposal on %@"),
                        target.connection.name
                    ),
                    messages: [.user(text)]
                )
            }
        )
    }

    private static func queryBlock(_ query: String) -> String {
        MCPPromptMarkdown.codeBlock(
            MCPPromptMarkdown.truncated(query, limit: queryExcerptLimit),
            language: "sql"
        )
    }

    private static func planSection(_ plan: String?) -> String {
        guard let plan, !plan.isEmpty else {
            return "\n## Explain plan\nNot provided. Say which EXPLAIN command to run and what to look for in it."
        }
        return "\n## Explain plan\n" + MCPPromptMarkdown.codeBlock(
            MCPPromptMarkdown.truncated(plan, limit: queryExcerptLimit),
            language: "text"
        )
    }

    private static func referencedTables(
        in query: String,
        inventory: [MCPPromptTableEntry],
        limit: Int
    ) -> [String] {
        let identifiers = Set(identifierTokens(in: query))
        let matched = inventory.filter { identifiers.contains($0.name.lowercased()) }
        guard !matched.isEmpty else { return [] }
        return matched.prefix(limit).map(\.name)
    }

    private static func identifierTokens(in query: String) -> [String] {
        query
            .lowercased()
            .split { character in
                !(character.isLetter || character.isNumber || character == "_")
            }
            .map(String.init)
    }
}
