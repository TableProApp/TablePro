//
//  ConnectionURLImportUsernameTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionURLImportUsernameTests {
    private func parse(_ urlString: String) throws -> ParsedConnectionURL {
        guard case .success(let parsed) = ConnectionURLParser.parse(urlString) else {
            throw ConnectionURLParseError.invalidURL
        }
        return parsed
    }

    @Test("Importing a MySQL URL with no user info keeps the username empty")
    func mysqlURLWithoutUserKeepsUsernameEmpty() throws {
        let parsed = try parse("mysql://localhost:3306/shop")
        let connection = TransientConnectionFactory.build(from: parsed)
        #expect(connection.username.isEmpty)
    }

    @Test("Importing a PostgreSQL URL with no user info keeps the username empty")
    func postgresURLWithoutUserKeepsUsernameEmpty() throws {
        let parsed = try parse("postgresql://db.example.com:5432/analytics")
        let connection = TransientConnectionFactory.build(from: parsed)
        #expect(connection.username.isEmpty)
    }

    @Test("A URL with user info still imports that username")
    func urlWithUserInfoKeepsUsername() throws {
        let parsed = try parse("mysql://admin:secret@localhost:3306/shop")
        let connection = TransientConnectionFactory.build(from: parsed)
        #expect(connection.username == "admin")
    }

    @Test("An opened MongoDB link keeps its secrets where the driver and backup tools read them, not as options")
    func openedMongoLinkRoutesSecrets() throws {
        let parsed = try parse(
            "mongodb://AKIA@db.example.com:27017/app?tls=true&authMechanism=MONGODB-AWS"
                + "&tlsCertificateKeyFile=%2Ftmp%2Fclient.pem&tlsCertificateKeyFilePassword=hunter2"
                + "&authMechanismProperties=AWS_SESSION_TOKEN%3AFQoG&proxyPassword=proxy-secret"
        )
        let connection = TransientConnectionFactory.build(from: parsed)

        #expect(connection.additionalFields["mongoAWSSessionToken"] == "FQoG")
        #expect(connection.additionalFields["sslClientKeyPassphrase"] == "hunter2")
        #expect(connection.sslConfig.clientCertificatePath == "/tmp/client.pem")
        #expect(!connection.additionalFields.keys.contains { $0.hasPrefix("mongoParam_") })
        let url = ConnectionURLFormatter.format(connection, password: "", sshPassword: nil)
        #expect(!url.contains("hunter2") && !url.contains("FQoG") && !url.contains("proxy-secret"))
    }

    @Test("An imported connection with no username exports a URL with no user info")
    func emptyUsernameRoundTripsThroughFormatter() throws {
        let parsed = try parse("mysql://localhost:3306/shop")
        let connection = TransientConnectionFactory.build(from: parsed)
        let url = ConnectionURLFormatter.format(connection, password: "", sshPassword: nil)
        #expect(!url.contains("@"))
        #expect(url.contains("localhost"))
    }
}
