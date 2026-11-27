//
//  ConnectionURLParserDuckDBTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct ConnectionURLParserDuckDBTests {
    private func parsed(_ url: String) throws -> ParsedConnectionURL {
        try ConnectionURLParser.parse(url).get()
    }

    @Test("A quack URL fills the Remote fields the DuckDB driver reads, direct and behind SSH", arguments: [
        ("quack://myhost:9495/analytics", "myhost", "9495", "analytics"),
        ("quack://[2001:db8::1]:9495/a%3Fb", "2001:db8::1", "9495", "a?b"),
        ("quack+ssh://deploy@bastion.example.com/quack.internal:9500/remotedb?sslmode=verify-full", "quack.internal", "9500", "remotedb")
    ])
    func quackURLFillsRemoteFields(url: String, host: String, port: String, alias: String) throws {
        let link = try parsed(url)
        #expect(link.additionalFields["duckdbMode"] == "remote")
        #expect(link.additionalFields["duckdbHost"] == host)
        #expect(link.additionalFields["duckdbPort"] == port)
        #expect(link.additionalFields["duckdbAlias"] == alias)
    }

    @Test("A quack URL with no port leaves the Port field to its default, one that names the default keeps it, and one with no path names the default alias")
    func quackURLDefaults() throws {
        let bare = try parsed("quack://myhost")
        #expect(bare.additionalFields["duckdbHost"] == "myhost")
        #expect(bare.additionalFields["duckdbPort"] == nil)
        #expect(bare.additionalFields["duckdbAlias"] == "remotedb")

        let defaultPort = try parsed("quack://myhost:9494/analytics")
        #expect(defaultPort.additionalFields["duckdbPort"] == "9494")
    }

    @Test("A MotherDuck string opens the MotherDuck type on its database, and names no file", arguments: [
        ("md:my_db", "my_db"),
        ("md:", ""),
        ("MD:my_db?attach_mode=single&motherduck_token=eyJ.a.b", "my_db"),
        ("md:_share/sample_data/6ae6172b", "_share/sample_data/6ae6172b")
    ])
    func motherDuckString(text: String, database: String) throws {
        let link = try parsed(text)
        #expect(link.type == .duckdb)
        #expect(link.additionalFields == ["duckdbMode": "motherduck", "duckdbMotherDuckDatabase": database])
        #expect(!link.namesDatabaseFile)
        #expect(link.password.isEmpty)
    }

    @Test("A copied MotherDuck row pastes back on the same database")
    @MainActor
    func motherDuckRoundTrip() throws {
        let conn = DatabaseConnection(
            name: "", database: "", type: .duckdb,
            additionalFields: ["duckdbMode": "motherduck", "duckdbMotherDuckDatabase": "my_db"]
        )
        let link = try parsed(ConnectionURLFormatter.format(conn, password: nil, sshPassword: nil))
        #expect(link.additionalFields["duckdbMotherDuckDatabase"] == "my_db")

        let percent = DatabaseConnection(
            name: "", database: "", type: .duckdb,
            additionalFields: ["duckdbMode": "motherduck", "duckdbMotherDuckDatabase": "sales%20archive"]
        )
        let literal = try parsed(ConnectionURLFormatter.format(percent, password: nil, sshPassword: nil))
        #expect(literal.additionalFields["duckdbMotherDuckDatabase"] == "sales%20archive")
    }

    @Test("A MotherDuck string with a control character is refused")
    func motherDuckStringWithControlCharacter() {
        #expect(throws: ConnectionURLParseError.invalidURL) { try ConnectionURLParser.parse("md:my\u{7}db").get() }
    }

    @Test("A duckdb file URL sets no Remote field")
    func fileURLSetsNoRemoteField() throws {
        let file = try parsed("duckdb:///Users/me/analytics.duckdb")
        #expect(file.additionalFields["duckdbMode"] == nil)
        #expect(file.additionalFields["duckdbHost"] == nil)
        #expect(file.additionalFields["duckdbAlias"] == nil)
    }
}
