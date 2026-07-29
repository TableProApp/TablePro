import XCTest
@testable import TableProImport

final class ConnectionImportDecoderTests: XCTestCase {
    func testEnvelopeRoundTripPreservesConnectionFields() throws {
        let connection = ExportableConnection(
            name: "Prod DB",
            host: "db.example.com",
            port: 5432,
            database: "app",
            username: "admin",
            type: "PostgreSQL",
            sshConfig: ExportableSSHConfig(
                enabled: true, host: "bastion", port: 2222, username: "deploy",
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
        XCTAssertEqual(result.port, 5432)
        XCTAssertEqual(result.type, "PostgreSQL")
        XCTAssertEqual(result.sshConfig?.host, "bastion")
        XCTAssertEqual(result.sshConfig?.port, 2222)
        XCTAssertEqual(result.sslConfig?.mode, "require")
        XCTAssertEqual(result.tagName, "production")
        XCTAssertEqual(result.additionalFields?["schema"], "public")
    }

    func testDecodeStripsBlockedAdditionalFields() throws {
        let connection = makeConnection(additionalFields: ["schema": "public", "preConnectScript": "rm -rf /"])
        let envelope = makeEnvelope(connections: [connection])
        let data = try ConnectionImportDecoder.encode(envelope)

        let decoded = try ConnectionImportDecoder.decodeData(data)
        let fields = try XCTUnwrap(decoded.connections.first?.additionalFields)
        XCTAssertEqual(fields["schema"], "public")
        XCTAssertNil(fields["preConnectScript"])
    }

    func testFutureFormatVersionThrows() throws {
        let envelope = ConnectionExportEnvelope(
            formatVersion: 999, exportedAt: Date(), appVersion: "1.0",
            connections: [], groups: nil, tags: nil, credentials: nil
        )
        let data = try ConnectionImportDecoder.encode(envelope)
        XCTAssertThrowsError(try ConnectionImportDecoder.decodeData(data))
    }

    func testEncryptedRoundTripThroughDecoder() throws {
        let envelope = makeEnvelope(connections: [makeConnection()])
        let json = try ConnectionImportDecoder.encode(envelope)
        let encrypted = try ConnectionExportCrypto.encrypt(data: json, passphrase: "hunter2")

        let decoded = try ConnectionImportDecoder.decodeEncryptedData(encrypted, passphrase: "hunter2")
        XCTAssertEqual(decoded.connections.count, 1)
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
    port: Int = 3306,
    database: String = "test",
    username: String = "root",
    type: String = "MySQL",
    additionalFields: [String: String]? = nil
) -> ExportableConnection {
    ExportableConnection(
        name: name, host: host, port: port, database: database, username: username, type: type,
        sshConfig: nil, sslConfig: nil, color: nil, tagName: nil, groupName: nil,
        sshProfileId: nil, safeModeLevel: nil, aiPolicy: nil,
        additionalFields: additionalFields, redisDatabase: nil, startupCommands: nil, localOnly: nil
    )
}

func makeEnvelope(connections: [ExportableConnection]) -> ConnectionExportEnvelope {
    ConnectionExportEnvelope(
        formatVersion: 1, exportedAt: Date(timeIntervalSince1970: 0), appVersion: "1.0",
        connections: connections, groups: nil, tags: nil, credentials: nil
    )
}
