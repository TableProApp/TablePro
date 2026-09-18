//
//  PostgreSQLServerVersionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("PostgreSQLServerVersion")
struct PostgreSQLServerVersionTests {
    @Test(
        "Parses the strings drivers and tools report into server_version_num form",
        arguments: [
            ("9.1.24", 90_124),
            ("9.2.23", 90_223),
            ("9.6.24", 90_624),
            ("10.21", 100_021),
            ("17.11", 170_011),
            ("17.11 (Homebrew)", 170_011),
            ("pg_dump (PostgreSQL) 17.11 (Homebrew)", 170_011),
            ("pg_dump (PostgreSQL) 9.1.24", 90_124),
            ("pg_dump (PostgreSQL) 12.22 (Debian 12.22-1.pgdg120+1)", 120_022),
            ("10beta2", 100_000),
            ("13.0.0", 130_000),
            ("8.0.2", 80_002),
            ("9.1", 90_100)
        ]
    )
    func parses(text: String, number: Int) {
        #expect(PostgreSQLServerVersion(text)?.number == number)
    }

    @Test("Text with no version number is not a version", arguments: ["", "PostgreSQL", "pg_dump (PostgreSQL)", "0.0"])
    func rejects(text: String) {
        #expect(PostgreSQLServerVersion(text) == nil)
    }

    @Test("A nil version string is not a version")
    func rejectsNil() {
        #expect(PostgreSQLServerVersion(nil) == nil)
    }

    @Test("Major release names follow PostgreSQL's two numbering schemes")
    func majorReleaseNames() {
        #expect(PostgreSQLServerVersion(number: 90_124).majorReleaseName == "9.1")
        #expect(PostgreSQLServerVersion(number: 170_011).majorReleaseName == "17")
        #expect(PostgreSQLServerVersion(number: 90_124).fullName == "9.1.24")
        #expect(PostgreSQLServerVersion(number: 170_011).fullName == "17.11")
    }

    @Test("Major release numbers compare the release, not the patch level")
    func majorReleaseNumbers() {
        #expect(PostgreSQLServerVersion(number: 90_124).majorReleaseNumber == 901)
        #expect(PostgreSQLServerVersion(number: 170_011).majorReleaseNumber == 1_700)
        #expect(PostgreSQLServerVersion(number: 170_002).majorReleaseNumber == 1_700)
    }
}

@Suite("PostgreSQLDumpToolCompatibility")
struct PostgreSQLDumpToolCompatibilityTests {
    private func version(_ text: String) throws -> PostgreSQLServerVersion {
        try #require(PostgreSQLServerVersion(text))
    }

    @Test(
        "pg_dump refuses servers newer than itself and, from 15, servers older than 9.2",
        arguments: [
            ("9.1.24", "17.11", false),
            ("9.1.24", "18.6", false),
            ("9.1.24", "14.13", true),
            ("9.1.24", "12.22", true),
            ("9.2.23", "17.11", true),
            ("9.6.24", "18.6", true),
            ("17.11", "17.2", true),
            ("17.11", "16.4", false),
            ("12.22", "9.6.24", false),
            ("9.1.24", "9.2.23", false),
            ("9.1.24", "9.3.25", true)
        ]
    )
    func canDump(server: String, tool: String, expected: Bool) throws {
        #expect(PostgreSQLDumpToolCompatibility.canDump(server: try version(server), with: try version(tool)) == expected)
    }

    @Test("The tool found on PATH wins when it can dump the server")
    func prefersPathTool() throws {
        let preferred = PostgreSQLDumpToolCompatibility.Candidate(path: "/opt/homebrew/bin/pg_dump", version: try version("17.11"))
        let other = PostgreSQLDumpToolCompatibility.Candidate(path: "/opt/homebrew/opt/libpq/bin/pg_dump", version: try version("18.6"))
        let chosen = PostgreSQLDumpToolCompatibility.choose(for: try version("12.22"), preferred: preferred, others: [other])
        #expect(chosen == preferred)
    }

    @Test("An older installed tool is chosen when the PATH tool refuses the server")
    func fallsBackToOlderTool() throws {
        let preferred = PostgreSQLDumpToolCompatibility.Candidate(path: "/opt/homebrew/bin/pg_dump", version: try version("17.11"))
        let fourteen = PostgreSQLDumpToolCompatibility.Candidate(
            path: "/opt/homebrew/opt/postgresql@14/bin/pg_dump", version: try version("14.13")
        )
        let twelve = PostgreSQLDumpToolCompatibility.Candidate(
            path: "/Applications/Postgres.app/Contents/Versions/12/bin/pg_dump", version: try version("12.22")
        )
        let chosen = PostgreSQLDumpToolCompatibility.choose(
            for: try version("9.1.24"), preferred: preferred, others: [twelve, fourteen]
        )
        #expect(chosen == fourteen)
    }

    @Test("Nothing is chosen when no installed tool can dump the server")
    func noCompatibleTool() throws {
        let preferred = PostgreSQLDumpToolCompatibility.Candidate(path: "/opt/homebrew/bin/pg_dump", version: try version("17.11"))
        #expect(PostgreSQLDumpToolCompatibility.choose(for: try version("9.1.24"), preferred: preferred, others: []) == nil)
    }

    @Test("The refusal for a 9.1 server names the tool, the 9.3 to 14 range and what was found")
    func refusalForOldServer() throws {
        let found = [
            PostgreSQLDumpToolCompatibility.Candidate(path: "/a", version: try version("18.6")),
            PostgreSQLDumpToolCompatibility.Candidate(path: "/b", version: try version("17.11"))
        ]
        let server = try version("9.1.24")
        let message = PostgreSQLDumpToolCompatibility.refusal(for: server, found: found, toolName: "pg_dump")
        #expect(message.contains("PostgreSQL 9.1 needs pg_dump 9.3 to 14."))
        #expect(message.contains("brew install postgresql@14"))
        #expect(message.contains("Found pg_dump 17.11 and 18.6."))
    }

    @Test("The refusal for a 7.x server stops at 9.6, the newest tool that reaches it")
    func refusalForPreEightServer() throws {
        let found = [PostgreSQLDumpToolCompatibility.Candidate(path: "/a", version: try version("17.11"))]
        let server = try version("7.4.30")
        let message = PostgreSQLDumpToolCompatibility.refusal(for: server, found: found, toolName: "pg_dump")
        #expect(message.contains("PostgreSQL 7.4 needs pg_dump 9.3 to 9.6."))
        #expect(!message.contains("postgresql@14"))
    }

    @Test("The refusal names pg_restore when it is pg_restore that cannot reach the server")
    func refusalNamesTheRestoreTool() throws {
        let found = [PostgreSQLDumpToolCompatibility.Candidate(path: "/a", version: try version("17.11"))]
        let server = try version("9.1.24")
        let message = PostgreSQLDumpToolCompatibility.refusal(for: server, found: found, toolName: "pg_restore")
        #expect(message.contains("PostgreSQL 9.1 needs pg_restore 9.3 to 14."))
        #expect(message.contains("Found pg_restore 17.11."))
    }

    @Test("The refusal for a server newer than every tool names that release")
    func refusalForNewServer() throws {
        let found = [PostgreSQLDumpToolCompatibility.Candidate(path: "/a", version: try version("17.11"))]
        let server = try version("19.0")
        let message = PostgreSQLDumpToolCompatibility.refusal(for: server, found: found, toolName: "pg_dump")
        #expect(message.contains("PostgreSQL 19 needs pg_dump 19 or later."))
        #expect(message.contains("brew install libpq"))
    }
}
