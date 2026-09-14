//
//  PasswordSourceCodableTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("PasswordSource Codable")
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
        #expect(try shape(.awsSecretsManager(
            secretId: "prod/db", jsonKey: "password", profile: "hms-product", region: "ap-southeast-1"
        )) == [
            "kind": "awsSecretsManager", "secretId": "prod/db", "jsonKey": "password",
            "profile": "hms-product", "region": "ap-southeast-1",
        ])
        /// An absent profile stays absent on the wire rather than encoding as an empty string,
        /// so a store written before the field existed decodes to exactly what it meant.
        #expect(try shape(.awsSecretsManager(secretId: "prod/db", jsonKey: nil, profile: nil, region: nil))
            == ["kind": "awsSecretsManager", "secretId": "prod/db"])
    }

    private func shape(_ source: PasswordSource) throws -> [String: String] {
        try decoder.decode([String: String].self, from: encoder.encode(source))
    }

    @Test("Round-trips every kind")
    func roundTrips() throws {
        let sources: [PasswordSource] = [
            .file(path: "~/db.pw"),
            .env(variable: "DB_PASS"),
            .command(shell: "op read op://vault/db/password"),
            .onePassword(reference: "op://vault/db/password"),
            .vault(path: "secret/data/db", field: "password"),
            .awsSecretsManager(
                secretId: "prod/db", jsonKey: "password", profile: "hms-product", region: "ap-southeast-1"
            ),
            .awsSecretsManager(secretId: "prod/db", jsonKey: nil, profile: nil, region: nil),
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

    @Test("A connection without a password source decodes to nil")
    func absentPasswordSourceIsNil() throws {
        let connection = DatabaseConnection(name: "plain", type: .mysql)
        let decoded = try decoder.decode(DatabaseConnection.self, from: encoder.encode(connection))
        #expect(decoded.passwordSource == nil)
    }
}
