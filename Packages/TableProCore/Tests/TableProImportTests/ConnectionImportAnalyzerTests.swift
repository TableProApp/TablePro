import XCTest
@testable import TableProImport

final class ConnectionImportAnalyzerTests: XCTestCase {
    private let allTypes: Set<String> = ["MySQL", "PostgreSQL", "Redis"]

    func testMatchingHostPortDatabaseUserIsDuplicate() {
        let existing = ConnectionDuplicateCandidate(
            id: UUID(), name: "Existing", host: "127.0.0.1", port: 3306,
            database: "test", username: "root", redisDatabase: nil
        )
        let envelope = makeEnvelope(connections: [makeConnection()])

        let preview = ConnectionImportAnalyzer.analyze(
            envelope, existingConnections: [existing], registeredTypeIds: allTypes, fileExists: { _ in true }
        )

        guard case .duplicate(let existingId, let existingName) = preview.items[0].status else {
            return XCTFail("expected duplicate")
        }
        XCTAssertEqual(existingId, existing.id)
        XCTAssertEqual(existingName, "Existing")
    }

    func testDifferentUsernameIsNotDuplicate() {
        let existing = ConnectionDuplicateCandidate(
            id: UUID(), name: "Existing", host: "127.0.0.1", port: 3306,
            database: "test", username: "someoneelse", redisDatabase: nil
        )
        let preview = ConnectionImportAnalyzer.analyze(
            makeEnvelope(connections: [makeConnection()]),
            existingConnections: [existing], registeredTypeIds: allTypes, fileExists: { _ in true }
        )
        guard case .ready = preview.items[0].status else {
            return XCTFail("expected ready")
        }
    }

    func testUnknownTypeProducesWarning() {
        let connection = makeConnection(type: "Cassandra")
        let preview = ConnectionImportAnalyzer.analyze(
            makeEnvelope(connections: [connection]),
            existingConnections: [], registeredTypeIds: allTypes, fileExists: { _ in true }
        )
        guard case .warnings(let messages) = preview.items[0].status else {
            return XCTFail("expected warnings")
        }
        XCTAssertTrue(messages.contains { $0.contains("Cassandra") })
    }

    func testMissingSSHKeyProducesWarning() {
        let connection = ExportableConnection(
            name: "x", host: "h", port: 22, database: "d", username: "u", type: "MySQL",
            sshConfig: ExportableSSHConfig(
                enabled: true, host: "bastion", port: nil, username: "u",
                authMethod: "privateKey", privateKeyPath: "~/.ssh/missing_key",
                agentSocketPath: "", jumpHosts: nil,
                totpMode: nil, totpAlgorithm: nil, totpDigits: nil, totpPeriod: nil
            ),
            sslConfig: nil, color: nil, tagName: nil, groupName: nil, sshProfileId: nil,
            safeModeLevel: nil, aiPolicy: nil, additionalFields: nil,
            redisDatabase: nil, startupCommands: nil, localOnly: nil
        )
        let preview = ConnectionImportAnalyzer.analyze(
            makeEnvelope(connections: [connection]),
            existingConnections: [], registeredTypeIds: allTypes, fileExists: { _ in false }
        )
        guard case .warnings(let messages) = preview.items[0].status else {
            return XCTFail("expected warnings")
        }
        XCTAssertTrue(messages.contains { $0.contains("SSH private key") })
    }

    func testRedisDatabaseDistinguishesDuplicates() {
        let existing = ConnectionDuplicateCandidate(
            id: UUID(), name: "Redis 0", host: "127.0.0.1", port: 6379,
            database: "", username: "", redisDatabase: 0
        )
        let connection = ExportableConnection(
            name: "Redis 1", host: "127.0.0.1", port: 6379, database: "", username: "", type: "Redis",
            sshConfig: nil, sslConfig: nil, color: nil, tagName: nil, groupName: nil, sshProfileId: nil,
            safeModeLevel: nil, aiPolicy: nil, additionalFields: nil,
            redisDatabase: 1, startupCommands: nil, localOnly: nil
        )
        let preview = ConnectionImportAnalyzer.analyze(
            makeEnvelope(connections: [connection]),
            existingConnections: [existing], registeredTypeIds: allTypes, fileExists: { _ in true }
        )
        guard case .ready = preview.items[0].status else {
            return XCTFail("expected ready: db index 1 differs from 0")
        }
    }
}
