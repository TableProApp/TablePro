import ArgumentParser
import Foundation
import TableProMCP

struct ExportCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export tables as CSV, JSON or SQL INSERT statements.",
        discussion: """
        Writes to standard output; redirect it to save a file:
          tablepro export -c Staging --format sql users > users.sql

        Each table stops at Default row limit in Settings > MCP unless --limit asks for more, up to \
        Maximum row limit. A cut-short table is named on standard error.
        """
    )

    @OptionGroup var connection: ConnectionOption
    @OptionGroup var database: DatabaseOption
    @OptionGroup var schema: SchemaOption

    @Option(help: ArgumentHelp("Export format.", valueName: "format"))
    var format: CLIExportFormat

    @OptionGroup var limit: LimitOption

    @Argument(help: ArgumentHelp("Tables to export, in order.", valueName: "table"))
    var tables: [String]

    func run(in session: CLISession) async throws {
        let client = try await session.connect()
        let connectionId = try await session.resolveConnection(connection.connection, client: client)
        var arguments: [String: JsonValue] = [
            "connection_id": .string(connectionId),
            "format": .string(format.rawValue),
            "tables": .array(tables.map(JsonValue.string))
        ]
        if let name = database.database { arguments["database"] = .string(name) }
        if let name = schema.schema { arguments["schema"] = .string(name) }
        if let rows = limit.limit { arguments["max_rows"] = .int(rows) }

        let result = try await session.call(client, "export_data", arguments)
        let exports = result["exports"]?.arrayValue ?? []
        let text = Self.joined(exports.map { $0["data"]?.stringValue ?? "" }, format: format)
        session.writeOutput(format == .json ? CLIRowWriter.jsonDocument(text) : text)
        for export in exports where export["is_truncated"]?.boolValue == true {
            let label = export["label"]?.stringValue ?? "a table"
            let count = export["row_count"]?.intValue ?? 0
            let shown = count == 1 ? "row" : "\(count) rows"
            session.writeError("tablepro: \(label): exported the first \(shown). Pass --limit to change it.")
        }
    }

    // Several JSON exports become one array of arrays, so the output stays one document, as on Linux.
    static func joined(_ documents: [String], format: CLIExportFormat) -> String {
        guard format == .json, documents.count > 1 else {
            return documents
                .map { $0.hasSuffix("\n") || $0.isEmpty ? $0 : $0 + "\n" }
                .joined(separator: "\n")
        }
        let arrays = documents.map { document in
            let end = document.lastIndex { !$0.isWhitespace }.map(document.index(after:)) ?? document.startIndex
            return document[..<end]
        }
        return "[\n" + arrays.joined(separator: ",\n") + "\n]\n"
    }
}
