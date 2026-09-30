@testable import TableProImport
import XCTest

final class ConnectionImportDecoderTests: XCTestCase {
    func testEnvelopeRoundTripPreservesConnectionFields() throws {
        let connection = ExportableConnection(
            name: "Prod DB",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "admin",
            type: "PostgreSQL",
            sshConfig: ExportableSSHConfig(
                enabled: true, host: "bastion", port: 2_222, username: "deploy",
                authMethod: "privateKey", privateKeyPath: "~/.ssh/id_ed25519",
                agentSocketPath: "", jumpHosts: nil,
                totpMode: nil, totpAlgorithm: nil, totpDigits: nil, totpPeriod: nil
            ),
            sslConfig: ExportableSSLConfig(mode: "require", caCertificatePath: nil, clientCertificatePath: nil, clientKeyPath: nil),
            color: "Blue",
            tagName: "production",
            groupName: "Work",
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            connectTimeoutSeconds: 12,
            queryTimeoutSeconds: 0,
            additionalFields: ["schema": "public"],
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )
        let envelope = ConnectionExportEnvelope(
            formatVersion: 1, exportedAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "1.0",
            connections: [connection], groups: nil, tags: nil, credentials: nil
        )

        let data = try ConnectionImportDecoder.encode(envelope)
        let decoded = try ConnectionImportDecoder.decodeData(data)

        let result = try XCTUnwrap(decoded.connections.first)
        XCTAssertEqual(result.name, "Prod DB")
        XCTAssertEqual(result.host, "db.example.com")
        XCTAssertEqual(result.port, 5_432)
        XCTAssertEqual(result.type, "PostgreSQL")
        XCTAssertEqual(result.sshConfig?.host, "bastion")
        XCTAssertEqual(result.sshConfig?.port, 2_222)
        XCTAssertEqual(result.sslConfig?.mode, "require")
        XCTAssertEqual(result.tagName, "production")
        XCTAssertEqual(result.connectTimeoutSeconds, 12)
        XCTAssertEqual(result.queryTimeoutSeconds, 0)
        XCTAssertEqual(result.additionalFields?["schema"], "public")
    }

    func testOlderEnvelopeWithoutTimeoutFieldsDecodesThemAsNil() throws {
        let json = Data(
            """
            {"formatVersion":1,"exportedAt":"1970-01-01T00:00:00Z","appVersion":"0.1",\
            "connections":[{"name":"Legacy","host":"localhost","port":3306,\
            "database":"","username":"","type":"MySQL"}]}
            """.utf8
        )

        let decoded = try ConnectionImportDecoder.decodeData(json)
        let connection = try XCTUnwrap(decoded.connections.first)

        XCTAssertNil(connection.connectTimeoutSeconds)
        XCTAssertNil(connection.queryTimeoutSeconds)
    }

    func testDecodeStripsBlockedAdditionalFields() throws {
        let connection = makeConnection(
            connectTimeoutSeconds: 12,
            queryTimeoutSeconds: 0,
            additionalFields: ["schema": "public", "preConnectScript": "rm -rf /"]
        )
        let envelope = makeEnvelope(connections: [connection])
        let data = try ConnectionImportDecoder.encode(envelope)

        let decoded = try ConnectionImportDecoder.decodeData(data)
        let fields = try XCTUnwrap(decoded.connections.first?.additionalFields)
        XCTAssertEqual(fields["schema"], "public")
        XCTAssertNil(fields["preConnectScript"])
        XCTAssertEqual(decoded.connections.first?.connectTimeoutSeconds, 12)
        XCTAssertEqual(decoded.connections.first?.queryTimeoutSeconds, 0)
    }

    func testConnectionCopiesPreserveTimeouts() {
        let connection = makeConnection(
            connectTimeoutSeconds: 12,
            queryTimeoutSeconds: 0,
            additionalFields: ["preConnectScript": "blocked", "schema": "public"]
        )

        let copies = [
            connection.retyped(to: "PostgreSQL"),
            connection.renamed(to: "Renamed"),
            connection.withoutStartupCommands(),
            connection.withoutTunnelCommand(),
            connection.sanitizedForImport()
        ]

        XCTAssertTrue(copies.allSatisfy { $0.connectTimeoutSeconds == 12 })
        XCTAssertTrue(copies.allSatisfy { $0.queryTimeoutSeconds == 0 })
    }

    func testImportRejectsInvalidExplicitTimeoutsInsteadOfFallingBackToLegacyFields() throws {
        let connection = makeConnection(
            connectTimeoutSeconds: 601,
            queryTimeoutSeconds: -1,
            additionalFields: [
                "connectTimeoutSeconds": "15",
                "queryTimeoutSeconds": "30",
                "schema": "public"
            ]
        )
        let data = try ConnectionImportDecoder.encode(makeEnvelope(connections: [connection]))

        let decoded = try ConnectionImportDecoder.decodeData(data)
        let imported = try XCTUnwrap(decoded.connections.first)

        XCTAssertNil(imported.connectTimeoutSeconds)
        XCTAssertNil(imported.queryTimeoutSeconds)
        XCTAssertEqual(imported.additionalFields, ["schema": "public"])
    }

    func testFutureFormatVersionThrows() throws {
        let envelope = ConnectionExportEnvelope(
            formatVersion: 999, exportedAt: Date(), appVersion: "1.0",
            connections: [], groups: nil, tags: nil, credentials: nil
        )
        let data = try ConnectionImportDecoder.encode(envelope)
        XCTAssertThrowsError(try ConnectionImportDecoder.decodeData(data))
    }

    func testEncryptedRoundTripThroughDecoder() async throws {
        let envelope = makeEnvelope(connections: [makeConnection()])
        let json = try ConnectionImportDecoder.encode(envelope)
        let encrypted = try await ConnectionExportCrypto.encrypt(data: json, passphrase: "hunter2")

        let decoded = try await ConnectionImportDecoder.decodeEncryptedData(encrypted, passphrase: "hunter2")
        XCTAssertEqual(decoded.connections.count, 1)
    }

    func testWrongPassphraseThroughDecoderThrowsDecryptionFailed() async throws {
        let json = try ConnectionImportDecoder.encode(makeEnvelope(connections: [makeConnection()]))
        let encrypted = try await ConnectionExportCrypto.encrypt(data: json, passphrase: "hunter2")

        do {
            _ = try await ConnectionImportDecoder.decodeEncryptedData(encrypted, passphrase: "hunter3")
            XCTFail("A wrong passphrase was expected to throw")
        } catch ConnectionExportError.decryptionFailed(let detail) {
            XCTAssertEqual(detail, ConnectionExportCryptoError.invalidPassphrase.localizedDescription)
        } catch {
            XCTFail("Expected decryptionFailed, got \(error)")
        }
    }

    func testPathPortabilityRoundTrips() {
        let original = NSHomeDirectory() + "/.ssh/id_rsa"
        let contracted = PathPortability.contractHome(original)
        XCTAssertTrue(contracted.hasPrefix("~/"))
        XCTAssertEqual(PathPortability.expandHome(contracted), original)
    }
}

func makeConnection(
    name: String = "Local",
    host: String = "127.0.0.1",
    port: Int = 3_306,
    database: String = "test",
    username: String = "root",
    type: String = "MySQL",
    connectTimeoutSeconds: Int? = nil,
    queryTimeoutSeconds: Int? = nil,
    additionalFields: [String: String]? = nil
) -> ExportableConnection {
    ExportableConnection(
        name: name, host: host, port: port, database: database, username: username, type: type,
        sshConfig: nil, sslConfig: nil, color: nil, tagName: nil, groupName: nil,
        sshProfileId: nil, safeModeLevel: nil, aiPolicy: nil,
        connectTimeoutSeconds: connectTimeoutSeconds, queryTimeoutSeconds: queryTimeoutSeconds,
        additionalFields: additionalFields, redisDatabase: nil, startupCommands: nil, localOnly: nil
    )
}

func makeEnvelope(connections: [ExportableConnection]) -> ConnectionExportEnvelope {
    ConnectionExportEnvelope(
        formatVersion: 1, exportedAt: Date(timeIntervalSince1970: 0), appVersion: "1.0",
        connections: connections, groups: nil, tags: nil, credentials: nil
    )
}
