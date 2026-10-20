//
//  PostgreSQLLocalSocketTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLLocalSocketTests {
    private func config(socket: String?, host: String = "localhost", port: Int = 5_432) -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: host,
            port: port,
            username: "",
            password: "",
            database: "app",
            additionalFields: socket.map { [PostgreSQLLocalSocket.fieldKey: $0] } ?? [:]
        )
    }

    @Test("A directory keeps the connection's port and names the file after it")
    func directory() {
        let endpoint = PostgreSQLLocalSocket.endpoint(path: "/var/run/postgresql", port: 5_433)
        #expect(endpoint == .init(directory: "/var/run/postgresql", port: 5_433))
        #expect(endpoint.socketFile == "/var/run/postgresql/.s.PGSQL.5433")
    }

    @Test("The socket file itself gives its directory, and the port in its name wins")
    func socketFile() {
        let endpoint = PostgreSQLLocalSocket.endpoint(path: "/tmp/.s.PGSQL.5433", port: 5_432)
        #expect(endpoint == .init(directory: "/tmp", port: 5_433))
        #expect(PostgreSQLLocalSocket.endpoint(path: "/.s.PGSQL.6000", port: 5_432) == .init(directory: "/", port: 6_000))
        #expect(PostgreSQLLocalSocket.endpoint(path: "/", port: 5_432).socketFile == "/.s.PGSQL.5432")
    }

    @Test("A trailing slash and surrounding space are dropped")
    func trailingSlash() {
        #expect(PostgreSQLLocalSocket.endpoint(path: " /tmp/ \n", port: 5_432) == .init(directory: "/tmp", port: 5_432))
        #expect(PostgreSQLLocalSocket.endpoint(path: "/tmp//", port: 5_432) == .init(directory: "/tmp", port: 5_432))
    }

    @Test(
        "A name that is not a socket file stays a directory",
        arguments: ["/tmp/.s.PGSQL.", "/tmp/.s.PGSQL.54x", "/tmp/.s.PGSQL.+5432", "/tmp/.s.PGSQL.0", "/tmp/.s.PGSQL.70000", "/tmp/.s.PGSQL.٥٤٣٢"]
    )
    func notASocketFileName(_ path: String) {
        #expect(PostgreSQLLocalSocket.endpoint(path: path, port: 5_432) == .init(directory: path, port: 5_432))
    }

    @Test("A relative path, a hidden character and a comma are rejected")
    func issues() {
        func issue(_ path: String) -> PostgreSQLLocalSocket.PathIssue? {
            PostgreSQLLocalSocket.issue(for: PostgreSQLLocalSocket.endpoint(path: path, port: 5_432))
        }
        #expect(issue("tmp") == .notAbsolute)
        #expect(issue("~/run") == .notAbsolute)
        #expect(issue("/tmp/a\u{0}b") == .hiddenCharacter)
        #expect(issue("/tmp/\u{202E}x") == .hiddenCharacter)
        #expect(issue("/tmp,/var/run/postgresql") == .comma)
        #expect(issue("/tmp") == nil)
        #expect(issue("/Users/me/Library/Application Support/Postgres/var-17") == nil)
    }

    @Test("The length that counts is the socket file's, which macOS caps at 103 bytes")
    func length() {
        let fits = "/" + String(repeating: "a", count: 88)
        #expect(PostgreSQLLocalSocket.endpoint(path: fits, port: 5_432).socketFile.utf8.count == 103)
        #expect(PostgreSQLLocalSocket.issue(for: .init(directory: fits, port: 5_432)) == nil)
        #expect(PostgreSQLLocalSocket.issue(for: .init(directory: fits, port: 54_321)) == .tooLong(bytes: 104))
    }

    @Test("~/.pgpass looks no host and /tmp up as localhost, any other directory by its path")
    func pgpassHost() {
        #expect(PostgreSQLLocalSocket.pgpassHost(forHost: "") == "localhost")
        #expect(PostgreSQLLocalSocket.pgpassHost(forHost: "/tmp") == "localhost")
        #expect(PostgreSQLLocalSocket.pgpassHost(forHost: "/var/run/postgresql") == "/var/run/postgresql")
        #expect(PostgreSQLLocalSocket.pgpassHost(forHost: "db.example.com") == "db.example.com")
    }

    @Test("A socket field hands libpq the directory as host and the port its file is named after")
    func driverEndpoint() throws {
        let server = try LibPQDriverCore.serverEndpoint(for: config(socket: "/tmp/.s.PGSQL.5433", host: "db.example.com"))
        #expect(server.host == "/tmp")
        #expect(server.port == 5_433)

        let directory = try LibPQDriverCore.serverEndpoint(for: config(socket: "/var/run/postgresql", port: 5_434))
        #expect(directory.host == "/var/run/postgresql")
        #expect(directory.port == 5_434)
    }

    @Test("Without a socket the host and port pass through")
    func driverEndpointWithoutSocket() throws {
        for socket in [nil, "", "  "] as [String?] {
            let server = try LibPQDriverCore.serverEndpoint(for: config(socket: socket, host: "db.example.com", port: 6_432))
            #expect(server.host == "db.example.com")
            #expect(server.port == 6_432)
        }
    }

    @Test("A path libpq would misread fails before it is dialed")
    func driverRejectsBadPath() {
        #expect(throws: LibPQPluginError.self) {
            try LibPQDriverCore.serverEndpoint(for: config(socket: "/tmp,/var/run/postgresql"))
        }
        #expect(throws: LibPQPluginError.self) {
            try LibPQDriverCore.serverEndpoint(for: config(socket: "relative/dir"))
        }
    }
}
