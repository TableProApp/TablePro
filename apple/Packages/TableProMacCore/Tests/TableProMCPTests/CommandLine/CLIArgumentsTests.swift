import Foundation
@testable import TableProMCP
import Testing

struct CLIArgumentsTests {
    private func query(_ arguments: [String]) throws -> CLIQueryOptions {
        guard case .query(let options) = try CLIArguments.parse(["query"] + arguments) else {
            Issue.record("Expected a query command")
            throw CLIFailure.usage("not a query")
        }
        return options
    }

    private func usageError(_ arguments: [String]) -> CLIFailure? {
        do {
            _ = try CLIArguments.parse(arguments)
            return nil
        } catch let failure as CLIFailure {
            return failure
        } catch {
            return nil
        }
    }

    @Test("Every query option is read, in both spellings")
    func readsEveryOption() throws {
        let options = try query([
            "--connection", "Staging", "--database=app", "--schema", "public", "--format", "CSV",
            "--limit", "20", "--timeout=5", "--read-only", "SELECT 1 AS n"
        ])
        #expect(options == CLIQueryOptions(
            connection: "Staging",
            database: "app",
            schema: "public",
            format: .csv,
            limit: 20,
            timeoutSeconds: 5,
            readOnly: true,
            sql: .argument("SELECT 1 AS n")
        ))
    }

    @Test("The SQL comes from the argument, a file, or standard input")
    func sqlSources() throws {
        #expect(try query(["-c", "x", "SELECT 1"]).sql == .argument("SELECT 1"))
        #expect(try query(["-c", "x", "-f", "q.sql"]).sql == .file("q.sql"))
        #expect(try query(["-c", "x", "--file", "-"]).sql == .standardInput)
        #expect(try query(["-c", "x"]).sql == .standardInput)
    }

    @Test("SQL that starts with a comment is SQL, not an option")
    func leadingCommentIsSql() throws {
        let sql = "-- report\nSELECT 1"
        #expect(try query(["-c", "x", sql]).sql == .argument(sql))
        #expect(try query(["-c", "x", "--", "-1"]).sql == .argument("-1"))
    }

    @Test("A connection name with a space survives the inline spelling")
    func inlineValueWithSpace() throws {
        #expect(try query(["--connection=My Prod", "SELECT 1"]).connection == "My Prod")
    }

    @Test("Usage mistakes exit 2")
    func usageMistakes() {
        let cases: [[String]] = [
            [],
            ["select"],
            ["query", "SELECT 1"],
            ["query", "-c", "x", "--format", "xml", "SELECT 1"],
            ["query", "-c", "x", "--limit", "0", "SELECT 1"],
            ["query", "-c", "x", "--timeout", "soon", "SELECT 1"],
            ["query", "-c", "x", "--bogus", "SELECT 1"],
            ["query", "-c", "x", "SELECT", "1"],
            ["query", "-c", "x", "-f", "q.sql", "SELECT 1"],
            ["query", "-c"],
            ["query", "-c", "x", "--read-only=yes", "SELECT 1"],
            ["connections", "extra"]
        ]
        for arguments in cases {
            #expect(usageError(arguments)?.exitCode == .usage, "\(arguments)")
        }
    }

    @Test("Help is a command of its own and wins over a missing connection")
    func help() throws {
        #expect(try CLIArguments.parse(["query", "--help"]) == .help(CLIArguments.queryUsage))
        #expect(try CLIArguments.parse(["connections", "-h"]) == .help(CLIArguments.connectionsUsage))
    }

    @Test("connections takes a format")
    func connections() throws {
        #expect(try CLIArguments.parse(["connections"]) == .connections(format: nil))
        #expect(try CLIArguments.parse(["connections", "--format", "json"]) == .connections(format: .json))
    }
}
