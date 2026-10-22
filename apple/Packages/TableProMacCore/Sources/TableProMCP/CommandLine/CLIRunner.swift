import Darwin
import Foundation

public protocol CLIConsole: AnyObject, Sendable {
    func out(_ text: String)
    func err(_ text: String)
}

public struct CLITerminal: Sendable, Equatable {
    public let standardInput: Bool
    public let standardOutput: Bool
    public let standardError: Bool

    public init(standardInput: Bool, standardOutput: Bool, standardError: Bool) {
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public static var current: CLITerminal {
        CLITerminal(
            standardInput: isatty(STDIN_FILENO) == 1,
            standardOutput: isatty(STDOUT_FILENO) == 1,
            standardError: isatty(STDERR_FILENO) == 1
        )
    }
}

// `appPath` is the bundle of the process serving MCP, which a pairing link has to reach.
public struct CLIServerEndpoint: Sendable, Equatable {
    public let port: Int
    public let appPath: String?

    public init(port: Int, appPath: String?) {
        self.port = port
        self.appPath = appPath
    }
}

public struct CLIRunner: Sendable {
    public typealias ServerOpener = @Sendable () async throws -> CLIServerEndpoint
    public typealias Pairer = @Sendable (_ server: CLIServerEndpoint) async throws -> String
    public typealias TextReader = @Sendable () throws -> String
    public typealias FileReader = @Sendable (_ path: String) throws -> String

    static let pairingTimeout: Duration = .seconds(330)

    private let console: any CLIConsole
    private let terminal: CLITerminal
    private let tokenStore: any CLITokenStoring
    private let openServer: ServerOpener
    private let pair: Pairer
    private let readStandardInput: TextReader
    private let readFile: FileReader

    public init(
        console: any CLIConsole,
        terminal: CLITerminal,
        tokenStore: any CLITokenStoring,
        openServer: @escaping ServerOpener,
        pair: @escaping Pairer,
        readStandardInput: @escaping TextReader,
        readFile: @escaping FileReader
    ) {
        self.console = console
        self.terminal = terminal
        self.tokenStore = tokenStore
        self.openServer = openServer
        self.pair = pair
        self.readStandardInput = readStandardInput
        self.readFile = readFile
    }

    public func run(arguments: [String]) async -> CLIExitCode {
        do {
            switch try CLIArguments.parse(arguments) {
            case .help(let text):
                console.out(text + "\n")
            case .connections(let format):
                try await listConnections(format: format ?? defaultFormat)
            case .query(let options):
                try await query(options)
            }
            return .success
        } catch let failure as CLIFailure {
            console.err("tablepro: \(failure.message)\n")
            return failure.exitCode
        } catch {
            console.err("tablepro: \(error.localizedDescription)\n")
            return .failure
        }
    }

    private var defaultFormat: CLIOutputFormat {
        terminal.standardOutput ? .table : .csv
    }

    private func listConnections(format: CLIOutputFormat) async throws {
        let client = try await connect()
        let listing = try await call(client, "list_connections", [:])
        var stream = ConsoleStream(console: console)
        CLIRowWriter.write(Self.connectionsSet(listing), as: format, to: &stream)
    }

    private func query(_ options: CLIQueryOptions) async throws {
        let sql = try readSql(options.sql)
        let client = try await connect()
        let connectionId = try await resolveConnection(options.connection, client: client)

        var arguments: [String: JsonValue] = [
            "connection_id": .string(connectionId),
            "query": .string(sql)
        ]
        if let database = options.database { arguments["database"] = .string(database) }
        if let schema = options.schema { arguments["schema"] = .string(schema) }
        if let limit = options.limit { arguments["max_rows"] = .int(limit) }
        if let timeout = options.timeoutSeconds { arguments["timeout_seconds"] = .int(timeout) }
        if options.readOnly { arguments["read_only"] = .bool(true) }

        let result = try await call(client, "execute_query", arguments)
        writeResult(result, format: options.format ?? defaultFormat)
    }

    private func writeResult(_ result: JsonValue, format: CLIOutputFormat) {
        let entries = result["result_sets"]?.arrayValue ?? [result]
        let sets = entries.map(Self.resultSet)
        var stream = ConsoleStream(console: console)
        CLIRowWriter.write(sets, as: format, to: &stream)
        for (entry, set) in zip(entries, sets) where entry["is_truncated"]?.boolValue == true {
            let shown = set.rows.count == 1 ? "row" : "\(set.rows.count) rows"
            console.err("tablepro: showing the first \(shown). Pass --limit to change it.\n")
        }
        if sets.allSatisfy({ $0.columns.isEmpty }), let affected = result["rows_affected"]?.intValue {
            console.err(affected == 1 ? "1 row affected.\n" : "\(affected) rows affected.\n")
        }
    }

    private func readSql(_ source: CLISqlSource) throws -> String {
        let text: String
        switch source {
        case .argument(let value):
            text = value
        case .file(let path):
            do {
                text = try readFile(path)
            } catch {
                throw CLIFailure.usage("Cannot read \(path): \(error.localizedDescription)")
            }
        case .standardInput:
            guard !terminal.standardInput else {
                throw CLIFailure.usage("Pass the SQL as an argument, with --file, or on standard input.")
            }
            text = try readStandardInput()
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIFailure.usage("The SQL is empty.")
        }
        return text
    }

    private func connect() async throws -> CLIServerClient {
        let server = try await openServer()
        if let token = try tokenStore.read() {
            return CLIServerClient(port: server.port, token: token)
        }
        guard terminal.standardError else {
            throw CLIFailure(
                .refused,
                "The tablepro command is not paired with TablePro yet. Run it once in Terminal to pair it."
            )
        }
        console.err("tablepro: approve the tablepro command in TablePro to pair it.\n")
        let token = try await pair(server)
        try tokenStore.save(token)
        return CLIServerClient(port: server.port, token: token)
    }

    private func call(_ client: CLIServerClient, _ tool: String, _ arguments: [String: JsonValue]) async throws -> JsonValue {
        do {
            return try await client.callTool(tool, arguments: arguments)
        } catch CLIServerClientError.tokenRejected {
            tokenStore.delete()
            throw CLIFailure(
                .refused,
                "TablePro no longer accepts this command's token: it was revoked or has expired. Run the command again to pair it."
            )
        }
    }

    private func resolveConnection(_ value: String, client: CLIServerClient) async throws -> String {
        if let id = UUID(uuidString: value) {
            return id.uuidString
        }
        let listing = try await call(client, "list_connections", [:])
        let entries = listing["connections"]?.arrayValue ?? []
        let exact = entries.filter { $0["name"]?.stringValue == value }
        let matches = exact.isEmpty
            ? entries.filter { $0["name"]?.stringValue?.caseInsensitiveCompare(value) == .orderedSame }
            : exact
        let ids = matches.compactMap { $0["id"]?.stringValue }
        guard let first = ids.first else {
            throw CLIFailure.usage(
                "No connection named \"\(value)\" is open to the tablepro command. Run tablepro connections to list them."
            )
        }
        guard ids.count == 1 else {
            throw CLIFailure.usage(
                "\(ids.count) connections are named \"\(value)\". Pass one of their ids: \(ids.joined(separator: ", "))."
            )
        }
        return first
    }

    static func resultSet(_ value: JsonValue) -> CLIResultSet {
        CLIResultSet(
            columns: value["columns"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            rows: value["rows"]?.arrayValue?.map { $0.arrayValue ?? [] } ?? []
        )
    }

    static func connectionsSet(_ listing: JsonValue) -> CLIResultSet {
        let rows = (listing["connections"]?.arrayValue ?? []).map { entry in
            [entry["name"] ?? .null, entry["id"] ?? .null, entry["type"] ?? .null]
        }
        return CLIResultSet(columns: ["name", "id", "type"], rows: rows)
    }
}

private struct ConsoleStream: TextOutputStream {
    let console: any CLIConsole

    mutating func write(_ string: String) {
        console.out(string)
    }
}

public extension CLIRunner {
    static func live(console: any CLIConsole) -> CLIRunner {
        CLIRunner(
            console: console,
            terminal: .current,
            tokenStore: CLITokenStores.current(),
            openServer: { try await openLiveServer() },
            pair: { server in try await pairLive(server: server) },
            readStandardInput: {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard let text = String(data: data, encoding: .utf8) else {
                    throw CLIFailure.usage("Standard input is not UTF-8 text.")
                }
                return text
            },
            readFile: { path in try String(contentsOfFile: path, encoding: .utf8) }
        )
    }

    // The server must prove it wrote the handshake before any token goes to its port.
    private static func openLiveServer() async throws -> CLIServerEndpoint {
        let logger = MCPOSBridgeLogger(category: "CLI")
        let handshake: MCPHandshakePayload
        do {
            handshake = try await MCPHandshakeAcquirer(logger: logger).acquire()
        } catch MCPHandshakeAcquisitionError.serverTurnedOff {
            throw CLIFailure(
                .refused,
                "TablePro's MCP server is turned off, and the tablepro command reaches TablePro through it. Turn it on under Settings > MCP."
            )
        } catch {
            throw CLIFailure(.failure, "TablePro did not start its MCP server: \(error.localizedDescription)")
        }
        guard let credentials = handshake.credentials() else {
            throw CLIFailure(.failure, "TablePro's MCP handshake names no usable port.")
        }
        do {
            _ = try await BridgeUpstreamHandshake.verifiedDiscovery(
                handshake: handshake,
                credentials: credentials,
                logger: logger
            )
        } catch {
            throw CLIFailure(.failure, "The local MCP server did not prove it is TablePro: \(error.localizedDescription)")
        }
        let appPath = MCPHandshakeTrust.executablePath(forPid: handshake.pid)
            .flatMap(MCPHandshakeTrust.appBundleRoot(forExecutable:))
        return CLIServerEndpoint(port: handshake.port, appPath: appPath)
    }

    private static func pairLive(server: CLIServerEndpoint) async throws -> String {
        let request = CLIPairingRequest.random()
        let listener = CLICallbackListener(state: request.state)
        defer { listener.stop() }

        let callbackPort: UInt16
        do {
            callbackPort = try await listener.start()
        } catch {
            throw CLIFailure(.failure, "Could not listen for the pairing answer: \(error.localizedDescription)")
        }
        guard let link = request.link(callbackPort: callbackPort) else {
            throw CLIFailure(.failure, "Could not build the pairing link.")
        }
        try openLink(link, in: server.appPath)

        switch await listener.waitForCallback(timeout: pairingTimeout) {
        case .approved(let code):
            return try await CLIServerClient.exchange(code: code, verifier: request.verifier, port: server.port)
        case .denied:
            throw CLIFailure(.refused, "Pairing was declined in TablePro.")
        case .ignored, nil:
            throw CLIFailure(.refused, "Pairing was not approved in time.")
        }
    }

    // The code is only good on the instance serving MCP, not on whichever copy owns `tablepro://`.
    private static func openLink(_ link: URL, in appPath: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = (appPath.map { ["-a", $0] } ?? []) + [link.absoluteString]
        do {
            try process.run()
        } catch {
            throw CLIFailure(.failure, "Could not open TablePro to pair: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIFailure(.failure, "Could not open TablePro to pair (open exited \(process.terminationStatus)).")
        }
    }
}
