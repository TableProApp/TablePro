//
//  PingNeverReconnectsTests.swift
//  TableProTests
//
//  A ping that heals its own connection reports success into a server session the app has just
//  lost: the startup commands, the query timeout, the database and the schema all belong to
//  `DatabaseManager.reconnectDriver`, and a private reconnect inside the driver re-runs none of
//  them. Failing instead is what routes recovery through the manager (#2700).
//
//  The driver sources are not in the test target, because they need their C bridges, so this is a
//  source scan rather than a behavioural test.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Ping never reconnects")
struct PingNeverReconnectsTests {
    /// Snowflake is the one deliberate exception. Its probe goes through `withReauthentication`,
    /// and an expired token is ordinary rather than a fault, so failing the ping would rebuild the
    /// driver every few hours instead of renewing the session it already has.
    private static let allowed: Set<String> = ["SnowflakeConnection.swift"]

    /// Calls that recover a dropped connection and replay, rather than reporting it.
    private static let reconnectingCalls = ["executeWithReconnect(", "SyncRetrying(", "boundedQueryWithReconnect("]

    @Test("no driver's ping routes through a call that reconnects and replays")
    func pingsDoNotHealThemselves() throws {
        var offenders: [String] = []

        for source in try Self.pluginSources() {
            guard !Self.allowed.contains(source.url.lastPathComponent) else { continue }
            /// A driver that has a reconnecting execute path must not reach its plain `execute`
            /// from a ping either: that is the indirection PostgreSQL's ping used, where the
            /// reconnect is a layer further down than the call site shows.
            let heals = source.text.contains("func executeWithReconnect(")
            for body in Self.pingBodies(in: source.text) {
                for call in Self.reconnectingCalls where body.contains(call) {
                    offenders.append("\(source.url.lastPathComponent): ping() calls \(call)")
                }
                if heals, body.contains("execute(query:") {
                    offenders.append("\(source.url.lastPathComponent): ping() calls execute(query:), which reconnects")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A ping must report a dropped connection rather than repair it, or the health check \
            succeeds against a session that lost its startup commands, query timeout, database and \
            schema: \(offenders.sorted())
            """
        )
    }

    /// Everything from a `func ping(` line to the first line closing it at the declaration's own
    /// indentation, which is enough to tell one function's body from its neighbours'.
    private static func pingBodies(in text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        var bodies: [String] = []
        for (index, line) in lines.enumerated() where line.contains("func ping(") {
            let indent = line.prefix { $0 == " " }.count
            let closing = String(repeating: " ", count: indent) + "}"
            guard let end = lines[(index + 1)...].firstIndex(of: closing) else { continue }
            bodies.append(lines[index ... end].joined(separator: "\n"))
        }
        return bodies
    }

    private struct PluginSource {
        let url: URL
        let text: String
    }

    private static func pluginSources(file: StaticString = #filePath) throws -> [PluginSource] {
        let root = try repositoryRoot(file: file).appendingPathComponent("Plugins")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw ScanError.sourcesNotFound
        }
        var sources: [PluginSource] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("func ping(") else { continue }
            sources.append(PluginSource(url: url, text: text))
        }
        guard !sources.isEmpty else { throw ScanError.sourcesNotFound }
        return sources
    }

    private static func repositoryRoot(file: StaticString) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Plugins/TableProPluginKit/DriverPlugin.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        throw ScanError.sourcesNotFound
    }

    private enum ScanError: Error {
        case sourcesNotFound
    }
}
