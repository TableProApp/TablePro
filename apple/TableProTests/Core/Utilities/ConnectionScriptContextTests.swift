//
//  ConnectionScriptContextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ConnectionScriptContextTests {
    private static func context(host: String = "db.example.com") -> ConnectionScriptContext {
        ConnectionScriptContext(
            connectionId: UUID(),
            connectionName: "Orders",
            host: host,
            port: 5_439,
            user: "app",
            database: "dev"
        )
    }

    @Test("The environment names the connection and never a password")
    func environmentNamesTheConnection() {
        #expect(Self.context().environment == [
            "TABLEPRO_CONNECTION_NAME": "Orders",
            "TABLEPRO_HOST": "db.example.com",
            "TABLEPRO_PORT": "5439",
            "TABLEPRO_USER": "app",
            "TABLEPRO_DATABASE": "dev"
        ])
    }

    @Test("A tunneled connection reports the host and port typed before the tunnel")
    func tunneledConnectionReportsTypedEndpoint() {
        var connection = TestFixtures.makeConnection(name: "Tunneled")
        connection.host = "127.0.0.1"
        connection.port = 61_000
        connection.additionalFields[DatabaseConnection.preTunnelHostKey] = "warehouse.internal"
        connection.additionalFields[DatabaseConnection.preTunnelPortKey] = "5439"

        let context = ConnectionScriptContext(connection: connection)

        #expect(context.host == "warehouse.internal")
        #expect(context.port == 5_439)
    }

    @Test("Each value reaches bash as one literal word however the placeholder is quoted", arguments: [
        "printf '%s|' {host} {port}",
        "printf '%s|' \"{host}\" \"{port}\"",
        "printf '%s|' '{host}' '{port}'"
    ])
    func placeholdersArriveLiteral(command: String) async throws {
        let hostile = "a b'c\"$(echo pwned)`echo x`\\"
        let output = try await PasswordSourceResolver.resolve(
            .command(shell: command),
            for: Self.context(host: hostile)
        )
        #expect(output == "\(hostile)|5439|")
    }

    @Test("A value is never run as code, inside a command substitution or a here-document either", arguments: [
        ("printf '%s' \"$(printf '%s' {database})\"", "x; printf INJECTED $(echo pwned)"),
        ("printf '%s' `printf '%s' {database}`", "x;printfINJECTED$(echopwned)"),
        ("cat <<EOF\n{database}\nEOF", "\"x; printf INJECTED $(echo pwned)\"")
    ])
    func nestedContextsStayLiteral(command: String, expected: String) async throws {
        let context = ConnectionScriptContext(
            connectionId: UUID(),
            connectionName: "Orders",
            host: "db.example.com",
            port: 5_439,
            user: "app",
            database: "x; printf INJECTED $(echo pwned)"
        )
        let output = try await PasswordSourceResolver.resolve(.command(shell: command), for: context)
        #expect(output == expected)
    }

    @Test("An apostrophe in a comment does not change how a later placeholder is quoted")
    func commentsDoNotChangeQuoting() async throws {
        let output = try await PasswordSourceResolver.resolve(
            .command(shell: "# John's token\nprintf '%s' {host} # it's the host"),
            for: Self.context()
        )
        #expect(output == "db.example.com")
    }

    @Test("A shell variable and an unknown name stay as written")
    func shellSyntaxIsLeftAlone() {
        let context = Self.context()
        #expect(context.substitutingPlaceholders(in: "echo ${host} {hostname} {}") == "echo ${host} {hostname} {}")
    }

    @Test("A password command sees the connection in its environment")
    func commandSeesEnvironment() async throws {
        let output = try await PasswordSourceResolver.resolve(
            .command(shell: "printf '%s@%s:%s/%s' \"$TABLEPRO_USER\" \"$TABLEPRO_HOST\" \"$TABLEPRO_PORT\" \"$TABLEPRO_DATABASE\""),
            for: Self.context()
        )
        #expect(output == "app@db.example.com:5439/dev")
    }

    @Test("One command shared by two connections answers each with its own host")
    func sharedCommandFollowsEachHost() async throws {
        let source = PasswordSource.command(shell: "printf 'token-for-%s' {host}")
        let first = try await PasswordSourceResolver.resolve(source, for: Self.context(host: "east.example.com"))
        let second = try await PasswordSourceResolver.resolve(source, for: Self.context(host: "west.example.com"))
        #expect(first == "token-for-east.example.com")
        #expect(second == "token-for-west.example.com")
    }
}
