import Foundation

public enum CLIOutputFormat: String, Sendable, Equatable, CaseIterable {
    case csv
    case tsv
    case json
    case jsonl
    case table
}

public enum CLISqlSource: Sendable, Equatable {
    case argument(String)
    case file(String)
    case standardInput
}

public struct CLIQueryOptions: Sendable, Equatable {
    public var connection: String
    public var database: String?
    public var schema: String?
    public var format: CLIOutputFormat?
    public var limit: Int?
    public var timeoutSeconds: Int?
    public var readOnly: Bool
    public var sql: CLISqlSource
}

public enum CLICommand: Sendable, Equatable {
    case query(CLIQueryOptions)
    case connections(format: CLIOutputFormat?)
    case help(String)
}

public enum CLIArguments {
    public static let queryUsage = """
    Usage: tablepro query --connection <name or id> [options] [SQL]

    Runs one statement through TablePro and prints the rows. The SQL comes from the
    argument, from -f <file>, or from standard input.

    Options:
      -c, --connection <name or id>  Saved connection to run against (required)
          --database <name>          Database to run against
          --schema <name>            Schema to run against
          --format <format>          csv, tsv, json, jsonl or table
                                     (table on a terminal, csv otherwise)
          --limit <rows>             Rows to return, up to the maximum in Settings > MCP
          --timeout <seconds>        Statement timeout, 1 to 300
          --read-only                Refuse any statement that is not a read
      -f, --file <path>              Read the SQL from a file, - for standard input
      -h, --help                     Show this help

    Exit status: 0 success, 1 query error, 2 usage error, 3 refused by policy, 4 timed out.
    """

    public static let connectionsUsage = """
    Usage: tablepro connections [--format <format>]

    Lists the saved connections the tablepro command can reach: name, id and type.

    Options:
          --format <format>  csv, tsv, json, jsonl or table (table on a terminal, csv otherwise)
      -h, --help             Show this help
    """

    public static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let subcommand = arguments.first else {
            throw CLIFailure.usage("Name a command: query or connections.")
        }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "query":
            return try parseQuery(rest)
        case "connections":
            return try parseConnections(rest)
        default:
            throw CLIFailure.usage("Unknown command \"\(subcommand)\". Use query or connections.")
        }
    }

    private static func parseQuery(_ arguments: [String]) throws -> CLICommand {
        var reader = OptionReader(arguments)
        var connection: String?
        var database: String?
        var schema: String?
        var format: CLIOutputFormat?
        var limit: Int?
        var timeout: Int?
        var readOnly = false
        var file: String?
        var positionals: [String] = []

        while let token = reader.next() {
            switch token {
            case .option(let name, let inline):
                switch name {
                case "-h", "--help":
                    return .help(queryUsage)
                case "-c", "--connection":
                    connection = try reader.value(for: name, inline: inline)
                case "--database":
                    database = try reader.value(for: name, inline: inline)
                case "--schema":
                    schema = try reader.value(for: name, inline: inline)
                case "--format":
                    format = try parseFormat(reader.value(for: name, inline: inline))
                case "--limit":
                    limit = try parsePositive(reader.value(for: name, inline: inline), option: name)
                case "--timeout":
                    timeout = try parsePositive(reader.value(for: name, inline: inline), option: name)
                case "--read-only":
                    guard inline == nil else { throw CLIFailure.usage("--read-only takes no value.") }
                    readOnly = true
                case "-f", "--file":
                    file = try reader.value(for: name, inline: inline)
                default:
                    throw CLIFailure.usage("Unknown option \(name). Run tablepro query --help.")
                }
            case .positional(let value):
                positionals.append(value)
            }
        }

        guard let connection, !connection.isEmpty else {
            throw CLIFailure.usage("Pass --connection with a connection's name or id.")
        }
        guard positionals.count <= 1 else {
            throw CLIFailure.usage("Pass the SQL as one quoted argument.")
        }

        let sql: CLISqlSource
        switch (positionals.first, file) {
        case (.some, .some):
            throw CLIFailure.usage("Pass the SQL as an argument or with --file, not both.")
        case (.some(let text), nil):
            sql = .argument(text)
        case (nil, .some(let path)):
            sql = path == "-" ? .standardInput : .file(path)
        case (nil, nil):
            sql = .standardInput
        }

        return .query(CLIQueryOptions(
            connection: connection,
            database: database,
            schema: schema,
            format: format,
            limit: limit,
            timeoutSeconds: timeout,
            readOnly: readOnly,
            sql: sql
        ))
    }

    private static func parseConnections(_ arguments: [String]) throws -> CLICommand {
        var reader = OptionReader(arguments)
        var format: CLIOutputFormat?
        while let token = reader.next() {
            switch token {
            case .option(let name, let inline):
                switch name {
                case "-h", "--help":
                    return .help(connectionsUsage)
                case "--format":
                    format = try parseFormat(reader.value(for: name, inline: inline))
                default:
                    throw CLIFailure.usage("Unknown option \(name). Run tablepro connections --help.")
                }
            case .positional(let value):
                throw CLIFailure.usage("Unexpected argument \"\(value)\".")
            }
        }
        return .connections(format: format)
    }

    private static func parseFormat(_ value: String) throws -> CLIOutputFormat {
        guard let format = CLIOutputFormat(rawValue: value.lowercased()) else {
            let names = CLIOutputFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw CLIFailure.usage("Unknown format \"\(value)\". Use one of \(names).")
        }
        return format
    }

    private static func parsePositive(_ value: String, option: String) throws -> Int {
        guard let number = Int(value), number > 0 else {
            throw CLIFailure.usage("\(option) takes a whole number above 0.")
        }
        return number
    }
}

private struct OptionReader {
    enum Token {
        case option(name: String, inline: String?)
        case positional(String)
    }

    private let arguments: [String]
    private var index = 0
    private var optionsEnded = false

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func next() -> Token? {
        guard index < arguments.count else { return nil }
        let argument = arguments[index]
        index += 1
        // An option name never holds whitespace, so "-- note\nSELECT 1" is SQL.
        let name = argument.split(separator: "=", maxSplits: 1).first ?? ""
        if optionsEnded || argument == "-" || !argument.hasPrefix("-") || name.contains(where: \.isWhitespace) {
            return .positional(argument)
        }
        if argument == "--" {
            optionsEnded = true
            return next()
        }
        if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
            return .option(
                name: String(argument[..<equals]),
                inline: String(argument[argument.index(after: equals)...])
            )
        }
        return .option(name: argument, inline: nil)
    }

    mutating func value(for option: String, inline: String?) throws -> String {
        if let inline {
            return inline
        }
        guard index < arguments.count else {
            throw CLIFailure.usage("\(option) needs a value.")
        }
        let value = arguments[index]
        index += 1
        return value
    }
}
