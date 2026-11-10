import ArgumentParser
import Foundation
import TableProMCP

struct ConnectionsCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "connections",
        abstract: "List the saved connections this command can use."
    )

    @OptionGroup var output: FormatOption

    func run(in session: CLISession) async throws {
        let client = try await session.connect()
        let listing = try await session.call(client, "list_connections", [:])
        let rows = (listing["connections"]?.arrayValue ?? []).map { entry in
            [entry["name"] ?? .null, entry["id"] ?? .null, entry["type"] ?? .null]
        }
        session.write([CLIResultSet(columns: ["name", "id", "type"], rows: rows)], format: output.format ?? session.defaultFormat)
    }
}

struct DatabasesCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "databases",
        abstract: "List a connection's databases."
    )

    @OptionGroup var connection: ConnectionOption
    @OptionGroup var output: FormatOption

    func run(in session: CLISession) async throws {
        let client = try await session.connect()
        let connectionId = try await session.resolveConnection(connection.connection, client: client)
        let listing = try await session.call(client, "list_databases", ["connection_id": .string(connectionId)])
        let rows = (listing["databases"]?.arrayValue ?? []).map { [$0] }
        session.write([CLIResultSet(columns: ["name"], rows: rows)], format: output.format ?? session.defaultFormat)
    }
}

struct SchemasCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "schemas",
        abstract: "List a connection's schemas."
    )

    @OptionGroup var connection: ConnectionOption
    @OptionGroup var database: DatabaseOption
    @OptionGroup var output: FormatOption

    func run(in session: CLISession) async throws {
        let client = try await session.connect()
        let connectionId = try await session.resolveConnection(connection.connection, client: client)
        var arguments: [String: JsonValue] = ["connection_id": .string(connectionId)]
        if let name = database.database { arguments["database"] = .string(name) }
        let listing = try await session.call(client, "list_schemas", arguments)
        let rows = (listing["schemas"]?.arrayValue ?? []).map { [$0] }
        session.write([CLIResultSet(columns: ["name"], rows: rows)], format: output.format ?? session.defaultFormat)
    }
}

struct TablesCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "tables",
        abstract: "List the tables and views in a schema."
    )

    @OptionGroup var connection: ConnectionOption
    @OptionGroup var database: DatabaseOption
    @OptionGroup var schema: SchemaOption
    @OptionGroup var output: FormatOption

    func run(in session: CLISession) async throws {
        let client = try await session.connect()
        let connectionId = try await session.resolveConnection(connection.connection, client: client)
        var arguments: [String: JsonValue] = ["connection_id": .string(connectionId)]
        if let name = database.database { arguments["database"] = .string(name) }
        if let name = schema.schema { arguments["schema"] = .string(name) }
        let listing = try await session.call(client, "list_tables", arguments)
        let rows = (listing["tables"]?.arrayValue ?? []).map { entry in
            [entry["schema"] ?? .null, entry["name"] ?? .null, entry["type"] ?? .null]
        }
        session.write([CLIResultSet(columns: ["schema", "name", "type"], rows: rows)], format: output.format ?? session.defaultFormat)
    }
}

struct DescribeCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "describe",
        abstract: "Show a table's columns, indexes and foreign keys.",
        discussion: "Indexes and foreign keys follow the columns as separate result sets when the table has any."
    )

    @OptionGroup var connection: ConnectionOption
    @OptionGroup var database: DatabaseOption
    @OptionGroup var schema: SchemaOption

    @Flag(help: "Print the CREATE statement instead.")
    var ddl = false

    @OptionGroup var output: FormatOption

    @Argument(help: ArgumentHelp("The table to describe.", valueName: "table"))
    var table: String

    func validate() throws {
        if ddl, output.format != nil {
            throw ValidationError("--ddl prints the statement as text, so it takes no --format.")
        }
    }

    func run(in session: CLISession) async throws {
        let client = try await session.connect()
        let connectionId = try await session.resolveConnection(connection.connection, client: client)
        var arguments: [String: JsonValue] = [
            "connection_id": .string(connectionId),
            "table": .string(table)
        ]
        if let name = database.database { arguments["database"] = .string(name) }
        if let name = schema.schema { arguments["schema"] = .string(name) }
        let description = try await session.call(client, "describe_table", arguments)

        if ddl {
            guard let statement = description["ddl"]?.stringValue, !statement.isEmpty else {
                throw CLIFailure(.failure, "TablePro could not produce a CREATE statement for \(table) on this engine.")
            }
            session.writeText(statement)
            return
        }
        session.write(Self.resultSets(description), format: output.format ?? session.defaultFormat)
    }

    static func resultSets(_ description: JsonValue) -> [CLIResultSet] {
        let columns = (description["columns"]?.arrayValue ?? []).map { column in
            [
                column["name"] ?? .null,
                column["data_type"] ?? .null,
                column["is_nullable"] ?? .null,
                column["default_value"] ?? .null,
                column["is_primary_key"] ?? .null
            ]
        }
        var sets = [CLIResultSet(columns: ["name", "type", "nullable", "default", "primary_key"], rows: columns)]

        let indexes = (description["indexes"]?.arrayValue ?? []).map { index in
            [
                index["name"] ?? .null,
                joined(index["columns"]),
                index["is_unique"] ?? .null,
                index["is_primary"] ?? .null
            ]
        }
        if !indexes.isEmpty {
            sets.append(CLIResultSet(columns: ["index", "columns", "unique", "primary"], rows: indexes))
        }

        let foreignKeys = (description["foreign_keys"]?.arrayValue ?? []).map { key in
            [
                key["name"] ?? .null,
                key["column"] ?? .null,
                key["referenced_table"] ?? .null,
                key["referenced_column"] ?? .null,
                key["on_delete"] ?? .null,
                key["on_update"] ?? .null
            ]
        }
        if !foreignKeys.isEmpty {
            sets.append(CLIResultSet(
                columns: ["foreign_key", "column", "referenced_table", "referenced_column", "on_delete", "on_update"],
                rows: foreignKeys
            ))
        }
        return sets
    }

    private static func joined(_ value: JsonValue?) -> JsonValue {
        guard let names = value?.arrayValue?.compactMap(\.stringValue) else { return .null }
        return .string(names.joined(separator: ", "))
    }
}
