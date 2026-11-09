import ArgumentParser
import Foundation
import TableProMCP

struct StatusCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether this command can reach TablePro.",
        discussion: """
        Never starts TablePro and never pairs. Exit status: 0 ready, 1 TablePro is not reachable, \
        3 the MCP server is off or this command is not paired.
        """
    )

    @OptionGroup var output: FormatOption

    func run(in session: CLISession) async throws {
        let environment = session.environment
        let probe = await environment.findServer()
        let token = try environment.tokenStore.read()

        var paired: Bool?
        if case .reachable(let server) = probe, let token {
            paired = try await CLIServerClient(socketPath: server.socketPath, serverPID: server.serverPID, token: token).tokenIsAccepted()
        } else if token == nil {
            paired = false
        }

        let report = Self.report(app: environment.app, probe: probe, paired: paired)
        session.write([report], format: output.format ?? session.defaultFormat)
        if let failure = Self.failure(probe: probe, paired: paired) {
            throw failure
        }
    }

    static func report(app: CLIHostApp, probe: CLIServerProbe, paired: Bool?) -> CLIResultSet {
        let running: Bool
        let serverOn: JsonValue
        switch probe {
        case .reachable:
            running = true
            serverOn = .bool(true)
        case .turnedOff:
            running = true
            serverOn = .bool(false)
        case .unreachable, .peerChanged:
            running = true
            serverOn = .null
        case .notRunning:
            running = false
            serverOn = .bool(false)
        }
        return CLIResultSet(
            columns: ["app", "version", "running", "mcp_server", "paired"],
            rows: [[
                app.url.map { .string($0.path) } ?? .null,
                app.version.map(JsonValue.string) ?? .null,
                .bool(running),
                serverOn,
                paired.map(JsonValue.bool) ?? .null
            ]]
        )
    }

    static func failure(probe: CLIServerProbe, paired: Bool?) -> CLIFailure? {
        switch probe {
        case .peerChanged:
            return .peerChanged
        case .notRunning:
            return CLIFailure(.failure, "TablePro is not running. Any command that needs it starts it.")
        case .unreachable(let reason):
            return CLIFailure(.failure, "TablePro's MCP server is not reachable: \(reason)")
        case .turnedOff:
            return CLIFailure(.refused, "TablePro's MCP server is turned off. Turn it on under Settings > MCP.")
        case .reachable:
            switch paired {
            case true?:
                return nil
            case false?:
                return CLIFailure(.refused, "This command is not paired with TablePro. Run tablepro pair.")
            case nil:
                return CLIFailure(.failure, "TablePro's MCP server did not answer whether this command is paired.")
            }
        }
    }
}

struct PairCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Pair this command with TablePro.",
        discussion: """
        Starts TablePro if needed and asks you to approve this command there. Pairing again replaces \
        the token this command holds and revokes the old one.
        """
    )

    func run(in session: CLISession) async throws {
        let environment = session.environment
        let server = try await environment.openServer()
        let previous = try? environment.tokenStore.read()
        session.writeError("tablepro: approve the tablepro command in TablePro to pair it.")
        let token = try await environment.pair(server)
        try environment.tokenStore.save(token)
        if let previous, previous != token {
            // The old token would otherwise stay listed and valid with no one holding it.
            let outcome = try? await CLIServerClient.revoke(token: previous, socketPath: server.socketPath, serverPID: server.serverPID)
            if outcome != .revoked {
                session.writeError("tablepro: The previous token is still active. Revoke it under Settings > MCP.")
            }
        }
        session.console.out("Paired with TablePro.\n")
    }
}

struct UnpairCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "unpair",
        abstract: "Remove this command's pairing.",
        discussion: """
        Asks TablePro to revoke this command's token, then deletes it from the Keychain. When \
        TablePro cannot be reached, the token is deleted here and stays listed under Settings > MCP \
        until you revoke it there. When TablePro cannot save the revocation, the token stays here so \
        you can try again.
        """
    )

    func run(in session: CLISession) async throws {
        let environment = session.environment
        guard let token = try environment.tokenStore.read() else {
            session.console.out("This command is not paired.\n")
            return
        }
        let probe = await environment.findServer()
        if case .peerChanged = probe {
            throw CLIFailure.peerChanged
        }
        guard case .reachable(let server) = probe else {
            environment.tokenStore.delete()
            throw CLIFailure(
                .failure,
                "Deleted this command's token, but TablePro's MCP server is not reachable to revoke it. It stays listed under Settings > MCP until you revoke it there."
            )
        }
        let outcome = try await CLIServerClient.revoke(token: token, socketPath: server.socketPath, serverPID: server.serverPID)
        switch outcome {
        case .revoked:
            environment.tokenStore.delete()
            session.console.out("Unpaired. TablePro revoked this command's token.\n")
        case .unavailable:
            // TablePro still accepts the token, so the copy here stays for another try.
            throw CLIFailure(
                .failure,
                "TablePro did not save the revocation, so this command's token still works and stays paired. Try tablepro unpair again, or revoke it under Settings > MCP."
            )
        case .refused(let reason):
            environment.tokenStore.delete()
            throw CLIFailure(
                .failure,
                "Deleted this command's token, but TablePro did not revoke it (\(reason)). Revoke it under Settings > MCP."
            )
        }
    }
}
