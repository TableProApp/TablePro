import ArgumentParser
import Foundation

protocol CLIRunnable {
    func run(in session: CLISession) async throws
}

struct TableProCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tablepro",
        abstract: "Open databases in TablePro and work with them from the shell.",
        discussion: """
        EXAMPLES:
          tablepro "postgresql://user@127.0.0.1:5432/app"
          tablepro schema.sql
          tablepro query -c Staging "SELECT id, email FROM users LIMIT 5"
          tablepro query -c Staging -f report.sql --format csv > report.csv
        """,
        version: CLIHostApp.current.versionLine,
        subcommands: [
            OpenCommand.self,
            QueryCommand.self,
            ConnectionsCommand.self,
            DatabasesCommand.self,
            SchemasCommand.self,
            TablesCommand.self,
            DescribeCommand.self,
            ExportCommand.self,
            StatusCommand.self,
            PairCommand.self,
            UnpairCommand.self,
            CompletionCommand.self
        ],
        defaultSubcommand: OpenCommand.self
    )

    // Owns the exit status: the library exits 64 on a usage error, and this command has always used 2.
    static func run(arguments: [String], environment: CLIEnvironment) async -> CLIExitCode {
        let session = CLISession(environment: environment)
        let command: ParsableCommand
        do {
            command = try await asyncParseAsRoot(arguments)
        } catch {
            return report(error, in: session)
        }

        guard let runnable = command as? any CLIRunnable else {
            var builtIn = command
            do {
                try builtIn.run()
                return .success
            } catch {
                return report(error, in: session)
            }
        }
        do {
            try await runnable.run(in: session)
            return .success
        } catch let failure as CLIFailure {
            session.writeError("tablepro: \(failure.message)")
            return failure.exitCode
        } catch {
            session.writeError("tablepro: \(error.localizedDescription)")
            return .failure
        }
    }

    // Help, --version and completion scripts arrive here as errors that exit 0.
    private static func report(_ error: Error, in session: CLISession) -> CLIExitCode {
        let code = exitCode(for: error)
        let message = fullMessage(for: error)
        if code == .success {
            if !message.isEmpty {
                session.console.out(message.hasSuffix("\n") ? message : message + "\n")
            }
            return .success
        }
        if !message.isEmpty {
            session.writeError(message)
        }
        if code == .validationFailure {
            return .usage
        }
        return CLIExitCode(rawValue: code.rawValue) ?? .failure
    }
}

public enum CommandLineTool {
    public static func main(arguments: [String]) async -> Int32 {
        let console = CLIStandardConsole()
        let code = await TableProCommand.run(arguments: arguments, environment: .live(console: console))
        console.flush()
        // A full disk or a closed file must not pass for a complete export.
        if let failure = console.outputFailure, code == .success {
            console.err("tablepro: could not write the output: \(failure.localizedDescription)\n")
            return CLIExitCode.failure.rawValue
        }
        return code.rawValue
    }
}
