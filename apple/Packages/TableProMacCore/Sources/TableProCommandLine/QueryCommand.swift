import ArgumentParser
import Foundation
import TableProMCP

struct QueryCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Run one SQL statement and print the rows.",
        discussion: """
        The SQL comes from the argument, from --file, or from standard input. Put SQL that starts \
        with a dash after --:
          tablepro query -c Staging -- "-- weekly report
          SELECT 1"

        Exit status: 0 done, 1 database or connection error, 2 usage error, 3 refused by a setting, \
        4 timed out.
        """
    )

    @OptionGroup var connection: ConnectionOption
    @OptionGroup var database: DatabaseOption
    @OptionGroup var schema: SchemaOption

    @Option(
        name: [.customShort("f"), .customLong("file")],
        help: ArgumentHelp("Read the SQL from a file, or - for standard input.", valueName: "path"),
        completion: .file()
    )
    var file: String?

    @OptionGroup var output: FormatOption
    @OptionGroup var limit: LimitOption

    @Option(help: ArgumentHelp("Statement timeout, 1 to 300.", valueName: "seconds"))
    var timeout: Int?

    @Flag(help: "Refuse any statement that is not a read.")
    var readOnly = false

    @Argument(help: ArgumentHelp("The statement to run.", valueName: "sql"))
    var sql: String?

    func validate() throws {
        if sql != nil, file != nil {
            throw ValidationError("Pass the SQL as an argument or with --file, not both.")
        }
        if let timeout, timeout < 1 {
            throw ValidationError("--timeout takes a whole number above 0.")
        }
    }

    var source: CLISqlSource {
        if let sql {
            return .argument(sql)
        }
        guard let file else { return .pipedInput }
        return file == "-" ? .standardInput : .file(file)
    }

    func run(in session: CLISession) async throws {
        let text = try session.readSql(source)
        let client = try await session.connect()
        let connectionId = try await session.resolveConnection(connection.connection, client: client)

        var arguments: [String: JsonValue] = [
            "connection_id": .string(connectionId),
            "query": .string(text)
        ]
        if let name = database.database { arguments["database"] = .string(name) }
        if let name = schema.schema { arguments["schema"] = .string(name) }
        if let rows = limit.limit { arguments["max_rows"] = .int(rows) }
        if let timeout { arguments["timeout_seconds"] = .int(timeout) }
        if readOnly { arguments["read_only"] = .bool(true) }

        let result = try await session.call(client, "execute_query", arguments)
        Self.write(result, format: output.format ?? session.defaultFormat, in: session)
    }

    static func write(_ result: JsonValue, format: CLIOutputFormat, in session: CLISession) {
        let entries = result["result_sets"]?.arrayValue ?? [result]
        let sets = entries.map(resultSet)
        session.write(sets, format: format)
        for (entry, set) in zip(entries, sets) where entry["is_truncated"]?.boolValue == true {
            let shown = set.rows.count == 1 ? "row" : "\(set.rows.count) rows"
            session.writeError("tablepro: showing the first \(shown). Pass --limit to change it.")
        }
        if sets.allSatisfy({ $0.columns.isEmpty }), let affected = result["rows_affected"]?.intValue {
            session.writeError(affected == 1 ? "1 row affected." : "\(affected) rows affected.")
        }
    }

    static func resultSet(_ value: JsonValue) -> CLIResultSet {
        CLIResultSet(
            columns: value["columns"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            rows: value["rows"]?.arrayValue?.map { $0.arrayValue ?? [] } ?? []
        )
    }
}
