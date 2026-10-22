//
//  PasswordSourceCodableTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct PasswordSourceCodableTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("Encodes each kind with the documented field names")
    func encodesDocumentedFieldNames() throws {
        #expect(try shape(.file(path: "p")) == ["kind": "file", "path": "p"])
        #expect(try shape(.env(variable: "V")) == ["kind": "env", "variable": "V"])
        #expect(try shape(.command(shell: "s")) == ["kind": "command", "shell": "s"])
        #expect(try shape(.onePassword(reference: "op://v/i/f")) == ["kind": "onePassword", "reference": "op://v/i/f"])
        #expect(try shape(.vault(path: "secret/db", field: "password"))
            == ["kind": "vault", "path": "secret/db", "field": "password"])
        #expect(try shape(.awsSecretsManager(secretId: "prod/db", jsonKey: "password"))
            == ["kind": "awsSecretsManager", "secretId": "prod/db", "jsonKey": "password"])
    }

    private func shape(_ source: PasswordSource) throws -> [String: String] {
        try decoder.decode([String: String].self, from: encoder.encode(source))
    }

    @Test("A command keeps how long its result may be reused, and drops a value out of range")
    func commandReuseSeconds() throws {
        let reused = PasswordSource.command(shell: "aws rds generate-db-auth-token", reuseSeconds: 600)
        #expect(try decoder.decode(PasswordSource.self, from: encoder.encode(reused)) == reused)

        let json = #"{"kind":"command","shell":"s","reuseSeconds":0}"#
        let decoded = try decoder.decode(PasswordSource.self, from: try #require(json.data(using: .utf8)))
        #expect(decoded == .command(shell: "s"))
    }

    @Test("Round-trips every kind")
    func roundTrips() throws {
        let sources: [PasswordSource] = [
            .file(path: "~/db.pw"),
            .env(variable: "DB_PASS"),
            .command(shell: "op read op://vault/db/password"),
            .onePassword(reference: "op://vault/db/password"),
            .vault(path: "secret/data/db", field: "password"),
            .awsSecretsManager(secretId: "prod/db", jsonKey: "password"),
            .awsSecretsManager(secretId: "prod/db", jsonKey: nil),
        ]
        for source in sources {
            let decoded = try decoder.decode(PasswordSource.self, from: encoder.encode(source))
            #expect(decoded == source)
        }
    }

    @Test("Decodes the documented JSON shape")
    func decodesDocumentedShape() throws {
        let json = #"{"kind":"file","path":"~/.config/tablepro/secrets/feature-x.pw"}"#
        let data = try #require(json.data(using: .utf8))
        let decoded = try decoder.decode(PasswordSource.self, from: data)
        #expect(decoded == .file(path: "~/.config/tablepro/secrets/feature-x.pw"))
    }

    @Test("Throws on an unknown kind")
    func throwsOnUnknownKind() throws {
        let json = #"{"kind":"azureKeyVault","reference":"x"}"#
        let data = try #require(json.data(using: .utf8))
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(PasswordSource.self, from: data)
        }
    }

    @Test("Round-trips through DatabaseConnection")
    func roundTripsThroughConnection() throws {
        var connection = DatabaseConnection(name: "worktree", type: .postgresql)
        connection.passwordSource = .command(shell: "op read op://vault/feature-x/password")
        let decoded = try decoder.decode(DatabaseConnection.self, from: encoder.encode(connection))
        #expect(decoded.passwordSource == .command(shell: "op read op://vault/feature-x/password"))
    }

    @Test("A Vault database role round-trips with each sign-in method", arguments: [
        VaultAuthMethod.token,
        .appRole(mount: "approle", roleId: "role-1", secretIdPath: "~/.vault/secret-id"),
        .oidc(mount: "oidc-corp", role: "dba"),
    ])
    func vaultDatabaseRoleRoundTrips(auth: VaultAuthMethod) throws {
        let source = PasswordSource.vaultDatabaseRole(
            VaultDatabaseRole(address: "https://vault.corp:8200", mount: "database", role: "readonly", auth: auth)
        )
        #expect(try decoder.decode(PasswordSource.self, from: encoder.encode(source)) == source)
    }

    @Test("Decodes the documented Vault database role shape, filling in the defaults")
    func decodesDocumentedVaultRole() throws {
        let tokenJSON = #"{"kind":"vaultDatabaseRole","mount":"database","role":"readonly"}"#
        #expect(try decoder.decode(PasswordSource.self, from: Data(tokenJSON.utf8))
            == .vaultDatabaseRole(VaultDatabaseRole(mount: "database", role: "readonly", auth: .token)))

        let appRoleJSON = #"{"kind":"vaultDatabaseRole","address":"https://vault.corp:8200","mount":"database","#
            + #""role":"readonly","auth":{"method":"approle","roleId":"r1","secretIdPath":"~/.vault/secret-id"}}"#
        #expect(try decoder.decode(PasswordSource.self, from: Data(appRoleJSON.utf8))
            == .vaultDatabaseRole(VaultDatabaseRole(
                address: "https://vault.corp:8200",
                mount: "database",
                role: "readonly",
                auth: .appRole(mount: "approle", roleId: "r1", secretIdPath: "~/.vault/secret-id")
            )))

        let oidcJSON = #"{"kind":"vaultDatabaseRole","mount":"database","role":"ro","auth":{"method":"oidc"}}"#
        #expect(try decoder.decode(PasswordSource.self, from: Data(oidcJSON.utf8))
            == .vaultDatabaseRole(VaultDatabaseRole(mount: "database", role: "ro", auth: .oidc(mount: "oidc", role: ""))))
    }

    @Test("A role reads its credentials under <mount>/creds/<role>")
    func credentialsPath() {
        #expect(VaultDatabaseRole(mount: "/database/", role: "readonly").credentialsPath == "database/creds/readonly")
        #expect(VaultDatabaseRole(mount: "teams/db", role: "rw").credentialsPath == "teams/db/creds/rw")
    }

    @Test("A connection without a password source decodes to nil")
    func absentPasswordSourceIsNil() throws {
        let connection = DatabaseConnection(name: "plain", type: .mysql)
        let decoded = try decoder.decode(DatabaseConnection.self, from: encoder.encode(connection))
        #expect(decoded.passwordSource == nil)
    }
}
