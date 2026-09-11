//
//  PostgreSQLDumpToolCompatibility.swift
//  TablePro
//

import Foundation

enum PostgreSQLDumpToolCompatibility {
    struct Candidate: Equatable, Sendable {
        let path: String
        let version: PostgreSQLServerVersion
    }

    /// `pg_dump` learned `-d` in 9.3, and every argument list here names the database with it.
    /// Measured: 9.2.23 answers `invalid option -- 'd'`, 9.3.25 runs.
    static let oldestUsableTool = PostgreSQLServerVersion(number: 90_300)

    private static let toolsDroppingPreNinePointTwoServers = PostgreSQLServerVersion(number: 150_000)
    private static let toolsDroppingPreEightServers = PostgreSQLServerVersion(number: 100_000)

    static func oldestServer(for tool: PostgreSQLServerVersion) -> PostgreSQLServerVersion {
        if tool >= toolsDroppingPreNinePointTwoServers {
            return PostgreSQLServerVersion(number: 90_200)
        }
        if tool >= toolsDroppingPreEightServers {
            return PostgreSQLServerVersion(number: 80_000)
        }
        return PostgreSQLServerVersion(number: 70_000)
    }

    static func canDump(server: PostgreSQLServerVersion, with tool: PostgreSQLServerVersion) -> Bool {
        guard tool >= oldestUsableTool else { return false }
        guard server.majorReleaseNumber <= tool.majorReleaseNumber else { return false }
        return server >= oldestServer(for: tool)
    }

    /// The newest tool release that still reaches this server, or nil when every later release does.
    /// `pg_dump` 10 dropped servers before 8.0 and 15 dropped servers before 9.2, so a 7.x server
    /// needs 9.6 or earlier and an 8.x or 9.1 server needs 14 or earlier.
    static func newestUsableTool(for server: PostgreSQLServerVersion) -> PostgreSQLServerVersion? {
        let ceilings = [
            (dropsServersBelow: 80_000, newestTool: 90_600),
            (dropsServersBelow: 90_200, newestTool: 140_000)
        ]
        for ceiling in ceilings where server.number < ceiling.dropsServersBelow {
            return PostgreSQLServerVersion(number: ceiling.newestTool)
        }
        return nil
    }

    static func choose(
        for server: PostgreSQLServerVersion,
        preferred: Candidate?,
        others: [Candidate]
    ) -> Candidate? {
        if let preferred, canDump(server: server, with: preferred.version) {
            return preferred
        }
        return others
            .filter { canDump(server: server, with: $0.version) }
            .max { $0.version < $1.version }
    }

    private static func installHint(newestUsableTool: PostgreSQLServerVersion?) -> String {
        guard let newestUsableTool else { return String(localized: "Install it with `brew install libpq`.") }
        guard newestUsableTool >= PostgreSQLServerVersion(number: 100_000) else {
            return String(
                format: String(localized: "Install one from PostgreSQL %@ or earlier."),
                newestUsableTool.majorReleaseName
            )
        }
        return String(
            format: String(localized: "Install one with `brew install postgresql@%@`."),
            newestUsableTool.majorReleaseName
        )
    }

    static func refusal(
        for server: PostgreSQLServerVersion,
        found: [Candidate],
        toolName: String
    ) -> String {
        let oldest = PostgreSQLServerVersion.release(
            max(oldestUsableTool.majorReleaseNumber, server.majorReleaseNumber)
        )
        let oldestName = oldest.majorReleaseName
        let requirement: String
        if let newest = newestUsableTool(for: server) {
            requirement = String(
                format: String(localized: "PostgreSQL %1$@ needs %2$@ %3$@ to %4$@."),
                server.majorReleaseName, toolName, oldestName, newest.majorReleaseName
            )
        } else {
            requirement = String(
                format: String(localized: "PostgreSQL %1$@ needs %2$@ %3$@ or later."),
                server.majorReleaseName, toolName, oldestName
            )
        }
        let install = installHint(newestUsableTool: newestUsableTool(for: server))
        let versions = Array(Set(found.map { $0.version })).sorted()
        guard !versions.isEmpty else { return "\(requirement) \(install)" }
        let foundList = versions.map(\.fullName).formatted(.list(type: .and))
        let foundSentence = String(
            format: String(localized: "Found %1$@ %2$@."), toolName, foundList
        )
        return "\(requirement) \(install) \(foundSentence)"
    }
}
