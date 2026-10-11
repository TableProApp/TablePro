//
//  ConnectionURLParserSocketTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct ConnectionURLParserSocketTests {
    private func parsed(_ url: String) throws -> ParsedConnectionURL {
        try ConnectionURLParser.parse(url).get()
    }

    @Test("socket= on a localhost MySQL URL is the socket path")
    func socketParameter() throws {
        let parsed = try parsed("mysql://root:pw@localhost/shop?socket=%2Ftmp%2Fmysql.sock")
        #expect(parsed.localSocketPath == "/tmp/mysql.sock")
        #expect(parsed.host == "localhost")
        #expect(parsed.database == "shop")
        #expect(parsed.username == "root")
        #expect(parsed.password == "pw")
    }

    @Test("unix_socket is read as socket, and socket wins when both are given")
    func unixSocketAlias() throws {
        #expect(try parsed("mysql://root@localhost/db?unix_socket=/tmp/mysql.sock").localSocketPath == "/tmp/mysql.sock")
        let both = try parsed("mysql://root@localhost/db?unix_socket=/tmp/b.sock&socket=/tmp/a.sock")
        #expect(both.localSocketPath == "/tmp/a.sock")
    }

    @Test("The parameter name is case-insensitive")
    func caseInsensitiveName() throws {
        #expect(try parsed("mysql://root@localhost/db?SOCKET=/tmp/mysql.sock").localSocketPath == "/tmp/mysql.sock")
    }

    @Test("The link a URLSearchParams caller builds keeps the space in Application Support")
    func formEncodedSpace() throws {
        let url = "mysql://root:root@localhost/local?socket=%2FUsers%2Fme%2FLibrary%2FApplication+Support"
            + "%2FLocal%2Frun%2Fab12%2Fmysql%2Fmysqld.sock&env=local&name=My+Site&safeModeLevel=0"
        let parsed = try parsed(url)
        #expect(parsed.localSocketPath == "/Users/me/Library/Application Support/Local/run/ab12/mysql/mysqld.sock")
        #expect(parsed.connectionName == "My Site")
        #expect(parsed.safeModeLevel == 0)
    }

    @Test("A percent-encoded plus stays a plus")
    func encodedPlus() throws {
        #expect(try parsed("mysql://root@localhost/db?socket=%2Ftmp%2Fa%2Bb.sock").localSocketPath == "/tmp/a+b.sock")
    }

    @Test("MySQL's parenthesized form drops the parentheses")
    func parenthesizedPath() throws {
        #expect(try parsed("mysql://root@localhost/db?socket=(/tmp/mysql.sock)").localSocketPath == "/tmp/mysql.sock")
    }

    @Test("An empty host becomes localhost when a socket is given")
    func emptyHostWithSocket() throws {
        let parsed = try parsed("mysql://root@/local?socket=/tmp/mysql.sock")
        #expect(parsed.host == "localhost")
        #expect(parsed.localSocketPath == "/tmp/mysql.sock")
        #expect(parsed.database == "local")
    }

    @Test("An empty host without a socket still needs a host")
    func emptyHostWithoutSocket() {
        guard case .failure(let error) = ConnectionURLParser.parse("mysql://root@/local") else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .missingHost)
    }

    @Test("LOCALHOST counts as localhost")
    func uppercaseLocalhost() throws {
        let parsed = try parsed("mysql://root@LOCALHOST/db?socket=/tmp/mysql.sock")
        #expect(parsed.localSocketPath == "/tmp/mysql.sock")
        #expect(parsed.host == "localhost")
    }

    @Test(
        "Any other host stays on TCP and ignores socket, as the mysql client does",
        arguments: ["127.0.0.1", "db.example.com", "[::1]"]
    )
    func otherHostIgnoresSocket(_ host: String) throws {
        let parsed = try parsed("mysql://root@\(host)/db?socket=/tmp/mysql.sock")
        #expect(parsed.localSocketPath == nil)
        #expect(parsed.additionalFields[MySQLLocalSocket.fieldKey] == nil)
    }

    @Test("MariaDB URLs take a socket too")
    func mariadb() throws {
        let parsed = try parsed("mariadb://root@localhost/db?socket=/tmp/mysql.sock")
        #expect(parsed.type == .mariadb)
        #expect(parsed.localSocketPath == "/tmp/mysql.sock")
    }

    @Test(
        "Engines without a socket mode ignore socket",
        arguments: [
            "postgresql://u@localhost/db?socket=/tmp/.s.PGSQL.5432",
            "tidb://root@localhost/db?socket=/tmp/mysql.sock",
            "redis://localhost?socket=/tmp/redis.sock"
        ]
    )
    func otherEnginesIgnoreSocket(_ url: String) throws {
        let parsed = try parsed(url)
        #expect(parsed.localSocketPath == nil)
        #expect(parsed.host == "localhost")
    }

    @Test("A PostgreSQL URL with no host still needs one, socket or not")
    func postgresEmptyHost() {
        guard case .failure(let error) = ConnectionURLParser.parse("postgresql://u@/db?socket=/tmp/x") else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .missingHost)
    }

    @Test("A relative socket path fails the URL")
    func relativePathFails() {
        guard case .failure(let error) = ConnectionURLParser.parse("mysql://root@localhost/db?socket=mysql.sock") else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .invalidSocketPath(.notAbsolute))
        #expect(error.errorDescription == MySQLLocalSocket.PathIssue.notAbsolute.message)
    }

    @Test("A home-relative socket path fails the URL")
    func tildePathFails() {
        guard case .failure(let error) = ConnectionURLParser.parse("mysql://root@localhost/db?socket=~/mysql.sock") else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .invalidSocketPath(.notAbsolute))
    }

    @Test(
        "A percent-encoded NUL or line break in the socket fails the URL, under either name",
        arguments: ["socket", "unix_socket"], ["%2Ftmp%2Fprod.sock%00%2F..%2Fdev.sock", "%2Ftmp%2Fa%0Ab.sock"]
    )
    func hiddenCharacterFails(_ name: String, _ value: String) {
        guard case .failure(let error) = ConnectionURLParser.parse("mysql://root@localhost/db?\(name)=\(value)") else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .invalidSocketPath(.hiddenCharacter))
    }

    @Test("103 bytes is the longest socket path, 104 fails")
    func lengthLimit() throws {
        let longest = "/" + String(repeating: "a", count: MySQLLocalSocket.maximumPathBytes - 1)
        #expect(try parsed("mysql://root@localhost/db?socket=\(longest)").localSocketPath == longest)

        let tooLong = longest + "a"
        guard case .failure(let error) = ConnectionURLParser.parse("mysql://root@localhost/db?socket=\(tooLong)") else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .invalidSocketPath(.tooLong(bytes: 104)))
    }

    @Test("An empty socket parameter is ignored")
    func emptyValue() throws {
        #expect(try parsed("mysql://root@localhost/db?socket=").localSocketPath == nil)
    }

    @Test("A socket in an SSH URL is ignored, the tunnel decides")
    func sshURLIgnoresSocket() throws {
        let parsed = try parsed("mysql+ssh://deploy@bastion.example.com/root@localhost/db?socket=/tmp/mysql.sock")
        #expect(parsed.sshHost == "bastion.example.com")
        #expect(parsed.localSocketPath == nil)
    }

    @Test("The port in a socket URL is not the endpoint")
    func socketURLWithPort() throws {
        let parsed = try parsed("mysql://root@localhost:3307/db?socket=/tmp/mysql.sock")
        #expect(parsed.localSocketPath == "/tmp/mysql.sock")
    }

    @Test("A socket URL builds a transient connection on that socket")
    @MainActor
    func transientConnection() throws {
        let parsed = try parsed("mysql://root@/local?socket=/tmp/mysql.sock&name=Local")
        let connection = TransientConnectionFactory.build(from: parsed)
        #expect(connection.localSocketPath == "/tmp/mysql.sock")
        #expect(connection.host == "localhost")
    }
}
