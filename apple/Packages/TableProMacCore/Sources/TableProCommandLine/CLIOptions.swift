import ArgumentParser
import Foundation

// --format has always taken any case; the library's own match is exact.
public enum CLIOutputFormat: String, Sendable, Equatable, CaseIterable, ExpressibleByArgument {
    case csv
    case tsv
    case json
    case jsonl
    case table

    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

enum CLIExportFormat: String, Sendable, Equatable, CaseIterable, ExpressibleByArgument {
    case csv
    case json
    case sql

    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

// An own type keeps CompletionShell free of a retroactive conformance.
enum CLIShell: String, Sendable, CaseIterable, ExpressibleByArgument {
    case bash
    case zsh
    case fish

    var completionShell: CompletionShell {
        switch self {
        case .bash: .bash
        case .zsh: .zsh
        case .fish: .fish
        }
    }
}

struct ConnectionOption: ParsableArguments {
    @Option(
        name: [.customShort("c"), .customLong("connection")],
        help: ArgumentHelp("A saved connection's name or id.", valueName: "connection")
    )
    var connection: String
}

struct FormatOption: ParsableArguments {
    @Option(help: ArgumentHelp("Output format: table on a terminal, csv otherwise.", valueName: "format"))
    var format: CLIOutputFormat?
}

struct DatabaseOption: ParsableArguments {
    @Option(help: ArgumentHelp("Database to use instead of the connection's own.", valueName: "name"))
    var database: String?
}

struct SchemaOption: ParsableArguments {
    @Option(help: ArgumentHelp("Schema to use instead of the connection's own.", valueName: "name"))
    var schema: String?
}

struct LimitOption: ParsableArguments {
    @Option(help: ArgumentHelp("Rows to return, up to Maximum row limit in Settings > MCP.", valueName: "rows"))
    var limit: Int?

    func validate() throws {
        if let limit, limit < 1 {
            throw ValidationError("--limit takes a whole number above 0.")
        }
    }
}
