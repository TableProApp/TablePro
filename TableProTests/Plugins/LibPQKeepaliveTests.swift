//
//  LibPQKeepaliveTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct LibPQKeepaliveTests {
    private static let pluginDirectory: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { directory.deleteLastPathComponent() }
        return directory
            .appendingPathComponent("Plugins")
            .appendingPathComponent("PostgreSQLDriverPlugin")
    }()

    private func build(options: String? = nil) -> String {
        LibPQConnectionString.build(
            host: "db.example.com",
            port: 5_432,
            user: "postgres",
            password: "hunter2",
            database: "app",
            sslConfig: SSLConfiguration(),
            options: options,
            applicationName: "TablePro",
            connectTimeoutSeconds: 10
        )
    }

    /// Reads the `keyword='value'` pairs the way libpq does, so a keyword spelled inside a quoted
    /// value, such as the connection options, is not counted as one of the connection's own.
    private func keywords(in conninfo: String) throws -> [String: [String]] {
        let pair = try NSRegularExpression(pattern: #"(\w+)='((?:[^'\\]|\\.)*)'"#)
        let text = conninfo as NSString
        var found: [String: [String]] = [:]
        for match in pair.matches(in: conninfo, range: NSRange(location: 0, length: text.length)) {
            found[text.substring(with: match.range(at: 1)), default: []]
                .append(text.substring(with: match.range(at: 2)))
        }
        return found
    }

    @Test("Every connection asks for a keepalive after 60 s idle, then 3 probes 10 s apart")
    func sendsKeepalives() throws {
        let found = try keywords(in: build())

        #expect(found["keepalives"] == ["1"])
        #expect(found["keepalives_idle"] == ["60"])
        #expect(found["keepalives_interval"] == ["10"])
        #expect(found["keepalives_count"] == ["3"])
    }

    /// Measured on macOS with the libpq the app ships: the `keepalives_*` values reach the socket,
    /// and `tcp_user_timeout` leaves `TCP_RXT_CONNDROPTIME` at 0.
    @Test("tcp_user_timeout is not sent, because macOS ignores it")
    func omitsUserTimeout() throws {
        #expect(try keywords(in: build())["tcp_user_timeout"] == nil)
    }

    /// The Connection Options field becomes libpq's `options` keyword, which the server reads as
    /// its own settings, so a user cannot set the client's keepalives there. The server's
    /// `tcp_keepalives_*` settings govern the server's end of the same socket and still apply.
    @Test(
        "Server keepalive settings in the connection options reach the server beside the client's own",
        arguments: ["-c tcp_keepalives_idle=30", "--tcp-keepalives-interval=5 -c tcp_keepalives_count=2"]
    )
    func serverKeepalivesStayInOptions(options: String) throws {
        let found = try keywords(in: build(options: options))

        #expect(found["options"] == [options])
        #expect(found["keepalives_idle"] == ["60"])
        #expect(found["keepalives_interval"] == ["10"])
        #expect(found["keepalives_count"] == ["3"])
    }

    @Test("The connection options stay the last keyword after the keepalives are added")
    func optionsStayLast() {
        #expect(build(options: "-c search_path=app").hasSuffix(" options='-c search_path=app'"))
    }

    /// The keepalives live in the conninfo builder, so they reach every PostgreSQL, Redshift,
    /// CockroachDB and PGlite connection only while that builder is the one way the plugin dials.
    @Test("The plugin opens libpq connections in one place, from the built conninfo")
    func oneConnectPath() throws {
        let sources: [(name: String, text: String)] = try FileManager.default
            .contentsOfDirectory(at: Self.pluginDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { (name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
        #expect(sources.contains { $0.name == "LibPQConnectionString.swift" })

        let otherDialers = ["PQconnectdb", "PQconnectdbParams", "PQconnectStartParams", "PQsetdbLogin"]
        let offenders = sources.flatMap { source in
            otherDialers.filter { source.text.contains("\($0)(") }.map { "\(source.name): \($0)" }
        }
        #expect(offenders.isEmpty, "\(offenders)")

        let starts = sources.filter { $0.text.contains("PQconnectStart(") }
        #expect(starts.map { $0.name } == ["LibPQPluginConnection.swift"])
        let connection = try #require(starts.first?.text)
        #expect(connection.components(separatedBy: "PQconnectStart(").count == 2)
        #expect(connection.contains("connectionString.withCString({ PQconnectStart($0) })"))
        #expect(connection.contains("private var connectionString: String {\n        LibPQConnectionString.build("))
    }
}
