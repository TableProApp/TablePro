import Foundation
@testable import TableProCommandLine
import TableProMCP
import TableProMCPTestSupport
import Testing

struct CLIParseTests {
    @Test("Help prints the command list on standard output and exits 0", arguments: [
        ["--help"], ["-h"], ["help"]
    ])
    func help(arguments: [String]) async throws {
        try await withRig { rig in
            #expect(await rig.run(arguments) == .success)
            #expect(rig.console.output.contains("USAGE: tablepro"))
            for command in ["open", "query", "connections", "databases", "schemas", "tables", "describe", "export", "status", "pair", "unpair", "completion"] {
                #expect(rig.console.output.contains(command), "\(command)")
            }
            #expect(rig.console.errors.isEmpty)
            #expect(rig.log.calls.isEmpty)
        }
    }

    @Test("A command's help explains it", arguments: [["help", "query"], ["query", "--help"]])
    func commandHelp(arguments: [String]) async throws {
        try await withRig { rig in
            #expect(await rig.run(arguments) == .success)
            #expect(rig.console.output.contains("Run one SQL statement"))
            #expect(rig.console.output.contains("--connection"))
        }
    }

    @Test("--version prints the version of the app the command ships in")
    func version() async throws {
        try await withRig { rig in
            #expect(await rig.run(["--version"]) == .success)
            #expect(rig.console.output == CLIHostApp.current.versionLine + "\n")
        }
    }

    @Test("No argument opens TablePro and nothing else")
    func bareCommandOpensTheApp() async throws {
        try await withRig { rig in
            #expect(await rig.run([]) == .success)
            #expect(rig.log.opened == [[]])
            #expect(await rig.server.requests.isEmpty)
        }
    }

    @Test("A URL or an existing file opens, with or without the open command")
    func openTargets() async throws {
        try await withRig { rig in
            let url = "postgresql://user@127.0.0.1:5432/app"
            #expect(await rig.run([url, "schema.sql"], files: ["/work/schema.sql"]) == .success)
            #expect(await rig.run(["open", "./status"], files: ["/work/status"]) == .success)
            #expect(rig.log.opened == [
                [URL(string: url), URL(fileURLWithPath: "/work/schema.sql")].compactMap { $0 },
                [URL(fileURLWithPath: "/work/status")]
            ])
        }
    }

    @Test("A word that is neither a command, a file nor a URL exits 2 and opens nothing", arguments: [
        ["qeury"], ["version"], ["open", "nosuch.sql"], ["c:query"]
    ])
    func unknownTarget(arguments: [String]) async throws {
        try await withRig { rig in
            #expect(await rig.run(arguments) == .usage)
            #expect(rig.console.errors.contains("no command or file named"))
            #expect(rig.log.opened.isEmpty)
        }
    }

    @Test("Usage mistakes exit 2 before anything reaches TablePro", arguments: [
        ["query", "SELECT 1"],
        ["query", "-c", "x", "--format", "xml", "SELECT 1"],
        ["query", "-c", "x", "--limit", "0", "SELECT 1"],
        ["query", "-c", "x", "--timeout", "soon", "SELECT 1"],
        ["query", "-c", "x", "--bogus", "SELECT 1"],
        ["query", "-c", "x", "SELECT", "1"],
        ["query", "-c", "x", "-f", "q.sql", "SELECT 1"],
        ["query", "-c"],
        ["query", "-c", "x", "--read-only=yes", "SELECT 1"],
        ["connections", "extra"],
        ["--bogus"],
        ["describe", "-c", "x", "--ddl", "--format", "json", "users"],
        ["describe", "-c", "x"],
        ["export", "-c", "x", "--format", "csv"],
        ["export", "-c", "x", "users"],
        ["export", "-c", "x", "--format", "xml", "users"],
        ["completion", "powershell"]
    ])
    func usageMistakes(arguments: [String]) async throws {
        try await withRig { rig in
            #expect(await rig.run(arguments) == .usage)
            #expect(!rig.console.errors.isEmpty)
            #expect(rig.console.output.isEmpty)
            #expect(rig.log.calls.isEmpty)
        }
    }

    @Test("completion prints a script for the shell")
    func completion() async throws {
        try await withRig { rig in
            #expect(await rig.run(["completion", "zsh"]) == .success)
            #expect(rig.console.output.hasPrefix("#compdef tablepro"))
            #expect(rig.log.calls.isEmpty)
        }
    }

    @Test("An open target resolves against the working directory, a URL needs a real scheme")
    func targetResolution() throws {
        let exists: (String) -> Bool = { $0 == "/work/data/app.db" || $0 == "/srv/app.db" }
        #expect(try OpenCommand.resolve("data/app.db", in: workDirectory, fileExists: exists) == URL(fileURLWithPath: "/work/data/app.db"))
        #expect(try OpenCommand.resolve("/srv/app.db", in: workDirectory, fileExists: exists) == URL(fileURLWithPath: "/srv/app.db"))
        #expect(try OpenCommand.resolve("tablepro://integrations/start-mcp", in: workDirectory, fileExists: exists).scheme == "tablepro")
        #expect(throws: CLIFailure.self) { try OpenCommand.resolve("", in: workDirectory, fileExists: exists) }
        #expect(throws: CLIFailure.self) { try OpenCommand.resolve("x:y", in: workDirectory, fileExists: exists) }
    }
}
