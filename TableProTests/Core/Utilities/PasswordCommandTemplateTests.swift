//
//  PasswordCommandTemplateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("PasswordCommandTemplate")
struct PasswordCommandTemplateTests {
    private func context(
        name: String = "prod",
        host: String = "db.example.com",
        port: Int = 5432,
        username: String = "app",
        database: String = "shop",
        typeId: String = "PostgreSQL"
    ) -> PasswordCommandTemplate.Context {
        PasswordCommandTemplate.Context(
            name: name, host: host, port: port, username: username, database: database, typeId: typeId
        )
    }

    @Test("Fills every placeholder it knows")
    func expandsKnownPlaceholders() {
        let expanded = PasswordCommandTemplate.expand(
            "get {name} {host} {port} {user} {database} {type}",
            with: context()
        )
        #expect(expanded == "get 'prod' 'db.example.com' '5432' 'app' 'shop' 'PostgreSQL'")
    }

    @Test("Quotes a value so it cannot break out into another command")
    func quotesInjection() {
        let expanded = PasswordCommandTemplate.expand("op read {name}", with: context(name: "a'; rm -rf ~; #"))
        #expect(expanded == #"op read 'a'\''; rm -rf ~; #'"#)
        #expect(!expanded.hasSuffix("#"))
    }

    @Test("Leaves a brace group it does not know alone")
    func passesUnknownBracesThrough() {
        let expanded = PasswordCommandTemplate.expand("vault read ${VAULT_PATH} | jq '{pw}'", with: context())
        #expect(expanded == "vault read ${VAULT_PATH} | jq '{pw}'")
    }

    @Test("Expands in one pass, so a value holding a token is not expanded again")
    func expandsOnce() {
        let expanded = PasswordCommandTemplate.expand("get {name}", with: context(name: "{host}"))
        #expect(expanded == "get '{host}'")
    }

    @Test("Leaves an unclosed brace as written")
    func leavesUnclosedBrace() {
        let expanded = PasswordCommandTemplate.expand("echo {name", with: context())
        #expect(expanded == "echo {name")
    }

    @Test("Takes the address the server answers on, not the tunnel's loopback port")
    func prefersPreTunnelEndpoint() {
        var connection = DatabaseConnection(id: UUID(), name: "tunneled")
        connection.host = "127.0.0.1"
        connection.port = 54_321
        connection.additionalFields["preTunnelHost"] = "db.internal"
        connection.additionalFields["preTunnelPort"] = "5432"

        let built = PasswordCommandTemplate.Context(connection: connection)
        #expect(built.host == "db.internal")
        #expect(built.port == 5432)
    }
}
