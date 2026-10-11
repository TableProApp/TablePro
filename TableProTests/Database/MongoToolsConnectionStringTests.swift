//
//  MongoToolsConnectionStringTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct MongoToolsConnectionStringTests {
    private func connection(
        host: String = "db.example.com",
        port: Int = 27_017,
        database: String = "shop",
        username: String = "alice",
        sslMode: SSLMode = .disabled
    ) -> DatabaseConnection {
        DatabaseConnection(
            name: "Test",
            host: host,
            port: port,
            database: database,
            username: username,
            type: .mongodb,
            sshConfig: SSHConfiguration(),
            sslConfig: SSLConfiguration(mode: sslMode)
        )
    }

    private func uri(_ connection: DatabaseConnection) -> String {
        MongoToolsConnectionString.make(for: connection, host: connection.host)
    }

    @Test("The auth database follows the driver's rule for every combination")
    func authenticationDatabaseMatchesTheDriver() {
        for explicit in [nil, "", "accounts", "$external"] {
            for database in ["", "shop"] {
                for useSrv in [false, true] {
                    var subject = connection(database: database)
                    subject.mongoAuthSource = explicit
                    subject.mongoUseSrv = useSrv
                    let driver = MongoDBAuthSourceResolver.resolve(
                        explicitAuthSource: explicit,
                        configuredDatabase: database,
                        useSrv: useSrv
                    )
                    #expect(
                        MongoToolsConnectionString.authenticationDatabase(for: subject) == driver,
                        "explicit \(explicit ?? "nil"), database \(database), srv \(useSrv)"
                    )
                }
            }
        }
    }

    @Test("An Atlas host is SRV without the toggle, as the driver treats it")
    func atlasHostImpliesSrv() {
        let atlas = uri(connection(host: "cluster0.abcde.mongodb.net"))
        #expect(atlas.hasPrefix("mongodb+srv://alice@cluster0.abcde.mongodb.net/?authSource=admin"))
        #expect(atlas.contains("tls=true"))
    }

    @Test("An SRV name loses the port the Hosts list gave it")
    func srvDropsThePort() {
        var subject = connection(host: "cluster0.example.com")
        subject.mongoUseSrv = true
        subject.additionalFields["mongoHosts"] = "cluster0.example.com:27017"
        #expect(uri(subject).hasPrefix("mongodb+srv://alice@cluster0.example.com/?"))
    }

    @Test("Hosts without a port take the connection's port, and an IPv6 literal keeps its brackets")
    func hostListPorts() {
        var subject = connection(port: 27_018)
        subject.additionalFields["mongoHosts"] = "a.example.com, [::1], b.example.com:27019, [fe80::1]:27020"
        #expect(uri(subject).hasPrefix(
            "mongodb://alice@a.example.com:27018,[::1]:27018,b.example.com:27019,[fe80::1]:27020/?"
        ))
    }

    @Test("A connection without a username sends no auth database, which the tools would try to use")
    func anonymousSendsNoAuthDatabase() {
        #expect(uri(connection(username: "")) == "mongodb://db.example.com:27017/")
    }

    @Test("Reserved characters in the username are percent-encoded")
    func usernameIsEncoded() {
        #expect(uri(connection(username: "pl+us@x:y/z%")).hasPrefix("mongodb://pl+us%40x%3Ay%2Fz%25@db.example.com"))
    }

    @Test("The connection's mechanism, replica set, read preference and write concern reach the tool")
    func connectionOptionsReachTheTool() {
        var subject = connection()
        subject.mongoAuthMechanism = "SCRAM-SHA-256"
        subject.mongoReplicaSet = "rs0"
        subject.mongoReadPreference = "secondaryPreferred"
        subject.mongoWriteConcern = "majority"
        #expect(uri(subject) == """
            mongodb://alice@db.example.com:27017/?authSource=shop&authMechanism=SCRAM-SHA-256\
            &replicaSet=rs0&readPreference=secondaryPreferred&w=majority
            """)
    }

    @Test("Extra URI parameters pass through unless a connection field owns them")
    func extraParametersPassThrough() {
        var subject = connection()
        subject.additionalFields["mongoParam_directConnection"] = "true"
        subject.additionalFields["mongoParam_authSource"] = "elsewhere"
        subject.additionalFields["mongoParam_readPreference"] = "nearest"
        subject.additionalFields["mongoParam_appName"] = "a&b=c+d"
        let plain = uri(subject)
        #expect(plain.contains("directConnection=true"))
        #expect(plain.contains("readPreference=nearest"))
        #expect(plain.contains("appName=a%26b%3Dc%2Bd"))
        #expect(!plain.contains("authSource=elsewhere"))

        subject.mongoReadPreference = "secondary"
        let owned = uri(subject)
        #expect(owned.contains("readPreference=secondary"))
        #expect(!owned.contains("readPreference=nearest"))
    }

    @Test("SSL off sends no TLS options and no certificate the form still holds")
    func tlsDisabled() {
        var subject = connection()
        subject.sslConfig.caCertificatePath = "/certs/ca.pem"
        subject.sslConfig.clientCertificatePath = "/certs/client.pem"
        #expect(MongoToolsConnectionString.tlsParameters(for: subject).isEmpty)
    }

    @Test("Preferred and Required skip verification with the one option the tools honor")
    func tlsWithoutVerification() {
        for mode in [SSLMode.preferred, .required] {
            var subject = connection(sslMode: mode)
            subject.sslConfig.caCertificatePath = "/certs/ca.pem"
            #expect(
                MongoToolsConnectionString.tlsParameters(for: subject) == ["tls=true", "tlsInsecure=true"],
                "\(mode.rawValue)"
            )
        }
    }

    @Test("The verifying modes send their CA and never switch verification off")
    func tlsWithVerification() {
        for mode in [SSLMode.verifyCa, .verifyIdentity] {
            var subject = connection(sslMode: mode)
            subject.sslConfig.caCertificatePath = "/certs/my ca.pem"
            subject.sslConfig.clientCertificatePath = "/certs/client.pem"
            #expect(
                MongoToolsConnectionString.tlsParameters(for: subject) == [
                    "tls=true", "tlsCAFile=/certs/my%20ca.pem", "tlsCertificateKeyFile=/certs/client.pem"
                ],
                "\(mode.rawValue)"
            )
        }
    }

    @Test("SRV turns TLS on with full verification when SSL is left off")
    func srvForcesTls() {
        var subject = connection()
        subject.mongoUseSrv = true
        subject.sslConfig.clientCertificatePath = "/certs/client.pem"
        #expect(MongoToolsConnectionString.tlsParameters(for: subject) == ["tls=true"])
    }
}
