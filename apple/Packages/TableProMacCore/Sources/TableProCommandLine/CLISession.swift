import Foundation
import TableProMCP

enum CLISqlSource: Sendable, Equatable {
    case argument(String)
    case file(String)
    // `-f -`: the user asked for standard input, so a terminal is read until end of file.
    case standardInput
    // No SQL at all: standard input only when something is piped in.
    case pipedInput
}

struct CLISession: Sendable {
    let environment: CLIEnvironment

    var console: any CLIConsole { environment.console }
    var terminal: CLITerminal { environment.terminal }
    var tokenStore: any CLITokenStoring { environment.tokenStore }

    var defaultFormat: CLIOutputFormat {
        terminal.standardOutput ? .table : .csv
    }

    // Every line on standard error is escaped: server text can carry a stored escape sequence.
    func writeError(_ line: String) {
        console.err(CLITerminalText.message(line) + "\n")
    }

    // Free text such as DDL is shown on a terminal, never run, and passes through untouched to a pipe.
    func writeText(_ text: String) {
        writeOutput(text.hasSuffix("\n") ? text : text + "\n")
    }

    func writeOutput(_ text: String) {
        console.out(terminal.standardOutput ? CLITerminalText.message(text) : text)
    }

    func write(_ sets: [CLIResultSet], format: CLIOutputFormat) {
        var stream = ConsoleStream(session: self)
        CLIRowWriter.write(sets, as: format, to: &stream)
    }

    func readSql(_ source: CLISqlSource) throws -> String {
        let text: String
        switch source {
        case .argument(let value):
            text = value
        case .file(let path):
            do {
                text = try environment.readFile(path)
            } catch {
                throw CLIFailure.usage("Cannot read \(path): \(error.localizedDescription)")
            }
        case .standardInput:
            text = try environment.readStandardInput()
        case .pipedInput:
            guard !terminal.standardInput else {
                throw CLIFailure.usage("Pass the SQL as an argument, with --file, or on standard input.")
            }
            text = try environment.readStandardInput()
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIFailure.usage("The SQL is empty.")
        }
        return text
    }

    func connect() async throws -> CLIServerClient {
        let server = try await environment.openServer()
        if let token = try tokenStore.read() {
            return CLIServerClient(socketPath: server.socketPath, serverPID: server.serverPID, token: token)
        }
        guard terminal.standardError else {
            throw CLIFailure(
                .refused,
                "The tablepro command is not paired with TablePro yet. Run tablepro pair in Terminal."
            )
        }
        writeError("tablepro: approve the tablepro command in TablePro to pair it.")
        let token = try await environment.pair(server)
        try tokenStore.save(token)
        return CLIServerClient(socketPath: server.socketPath, serverPID: server.serverPID, token: token)
    }

    func call(_ client: CLIServerClient, _ tool: String, _ arguments: [String: JsonValue]) async throws -> JsonValue {
        do {
            return try await client.callTool(tool, arguments: arguments)
        } catch CLIServerClientError.tokenRejected {
            tokenStore.delete()
            throw CLIFailure(
                .refused,
                "TablePro no longer accepts this command's token: it was revoked or has expired. Run tablepro pair to pair it again."
            )
        }
    }

    // One lookup for ids and names, so a connection hidden from this command and one that does not
    // exist end in the same exit status.
    func resolveConnection(_ value: String, client: CLIServerClient) async throws -> String {
        let listing = try await call(client, "list_connections", [:])
        let entries = listing["connections"]?.arrayValue ?? []
        if let id = UUID(uuidString: value) {
            let match = entries.lazy
                .compactMap { $0["id"]?.stringValue }
                .first { UUID(uuidString: $0) == id }
            if let match {
                return match
            }
        }
        let exact = entries.filter { $0["name"]?.stringValue == value }
        let matches = exact.isEmpty
            ? entries.filter { $0["name"]?.stringValue?.caseInsensitiveCompare(value) == .orderedSame }
            : exact
        let ids = matches.compactMap { $0["id"]?.stringValue }
        guard let first = ids.first else {
            let subject = UUID(uuidString: value) == nil ? "named \"\(value)\"" : "with the id \(value)"
            throw CLIFailure.usage(
                "No connection \(subject) is open to the tablepro command. Run tablepro connections to list them."
            )
        }
        guard ids.count == 1 else {
            throw CLIFailure.usage(
                "\(ids.count) connections are named \"\(value)\". Pass one of their ids: \(ids.joined(separator: ", "))."
            )
        }
        return first
    }
}

private struct ConsoleStream: TextOutputStream {
    let session: CLISession

    mutating func write(_ string: String) {
        session.writeOutput(string)
    }
}
