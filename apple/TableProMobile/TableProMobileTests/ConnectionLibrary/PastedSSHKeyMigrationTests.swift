import Foundation
import TableProModels
import Testing

@testable import TableProMobile

@Suite("Pasted SSH key migration")
struct PastedSSHKeyMigrationTests {
    private func libraryFile(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries)
    }

    private func entry(_ id: UUID, ssh: [String: Any]?) -> [String: Any] {
        var entry: [String: Any] = ["id": id.uuidString, "name": "Conn", "type": "PostgreSQL"]
        if let ssh {
            entry["sshConfiguration"] = ssh
        }
        return entry
    }

    private func tunnelled() -> DatabaseConnection {
        DatabaseConnection(
            name: "Bastion",
            type: .postgresql,
            host: "10.0.0.5",
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "bastion.example.com", username: "deploy", authMethod: .privateKey)
        )
    }

    @Test("Reads each pasted key by connection id")
    func readsKeysById() throws {
        let first = UUID()
        let second = UUID()
        let data = try libraryFile([
            entry(first, ssh: ["host": "a", "authMethod": "privateKey", "privateKeyData": "KEY A"]),
            entry(second, ssh: ["host": "b", "authMethod": "privateKey", "privateKeyData": "KEY B"])
        ])

        #expect(PastedSSHKeyMigration.pendingKeys(inLibraryFile: data) == [first: "KEY A", second: "KEY B"])
    }

    @Test("Skips connections with no SSH, an empty key, or only a key file")
    func skipsEntriesWithoutKeyText() throws {
        let data = try libraryFile([
            entry(UUID(), ssh: nil),
            entry(UUID(), ssh: ["host": "a", "authMethod": "privateKey", "privateKeyData": ""]),
            entry(UUID(), ssh: ["host": "b", "authMethod": "privateKey", "privateKeyPath": "/keys/id_rsa"])
        ])

        #expect(PastedSSHKeyMigration.pendingKeys(inLibraryFile: data).isEmpty)
    }

    @Test("The first key for a repeated id wins")
    func firstKeyWins() throws {
        let id = UUID()
        let data = try libraryFile([
            entry(id, ssh: ["privateKeyData": "FIRST"]),
            entry(id, ssh: ["privateKeyData": "SECOND"])
        ])

        #expect(PastedSSHKeyMigration.pendingKeys(inLibraryFile: data) == [id: "FIRST"])
    }

    @Test("A record it cannot read does not hide the keys of the others")
    func unreadableRecordKeepsOtherKeys() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            entry(id, ssh: ["privateKeyData": "KEY A"]),
            ["name": "No id", "sshConfiguration": ["privateKeyData": "KEY B"]],
            NSNull()
        ] as [Any])

        #expect(PastedSSHKeyMigration.pendingKeys(inLibraryFile: data) == [id: "KEY A"])
    }

    @Test("A kept key goes back into a file that also holds entries that are not objects")
    func keptKeyBesideNonObjectEntries() throws {
        let connection = tunnelled()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(connection))
        let encoded = try JSONSerialization.data(withJSONObject: [object, NSNull(), "text"] as [Any])

        let written = try PastedSSHKeyMigration.libraryFile(encoded, keeping: [connection.id: "KEY A"])

        #expect(PastedSSHKeyMigration.pendingKeys(inLibraryFile: written) == [connection.id: "KEY A"])
        #expect((try JSONSerialization.jsonObject(with: written) as? [Any])?.count == 3)
    }

    @Test("A file it cannot read yields nothing to migrate")
    func unreadableFile() {
        #expect(PastedSSHKeyMigration.pendingKeys(inLibraryFile: Data("{ not json".utf8)).isEmpty)
        #expect(PastedSSHKeyMigration.pendingKeys(inLibraryFile: Data("[]".utf8)).isEmpty)
    }

    @Test("A key kept in the file reads back as pending, and the file still decodes to the same connections")
    func keptKeyRoundTrips() throws {
        let connections = [tunnelled(), DatabaseConnection(name: "Local", type: .mysql)]
        let encoded = try JSONEncoder().encode(connections)

        let written = try PastedSSHKeyMigration.libraryFile(encoded, keeping: [connections[0].id: "KEY A"])

        #expect(PastedSSHKeyMigration.pendingKeys(inLibraryFile: written) == [connections[0].id: "KEY A"])
        #expect(try JSONDecoder().decode([DatabaseConnection].self, from: written) == connections)
    }

    @Test("With nothing to keep, the encoded file is written as it is")
    func nothingToKeep() throws {
        let encoded = try JSONEncoder().encode([tunnelled()])

        #expect(try PastedSSHKeyMigration.libraryFile(encoded, keeping: [:]) == encoded)
    }

    @Test("A key has nowhere to go without its connection or that connection's SSH settings")
    func keyNeedsItsConnection() throws {
        let plain = DatabaseConnection(name: "Local", type: .mysql)
        let encoded = try JSONEncoder().encode([plain])

        let written = try PastedSSHKeyMigration.libraryFile(encoded, keeping: [plain.id: "KEY A", UUID(): "KEY B"])

        #expect(PastedSSHKeyMigration.pendingKeys(inLibraryFile: written).isEmpty)
    }

    @Test("A key no longer held leaves the file, and one with no id to file it under stays")
    func movedKeyLeavesKeptRecords() throws {
        let moved = UUID()
        let encoded = try JSONSerialization.data(withJSONObject: [
            entry(moved, ssh: ["privateKeyData": "KEY A"]),
            ["name": "No id", "sshConfiguration": ["privateKeyData": "KEY B"]]
        ] as [Any])

        let written = try PastedSSHKeyMigration.libraryFile(encoded, keeping: [:])

        let text = try #require(String(data: written, encoding: .utf8))
        #expect(!text.contains("KEY A"))
        #expect(text.contains("KEY B"))
        #expect((try JSONSerialization.jsonObject(with: written) as? [Any])?.count == 2)
    }

    @Test("A key of a connection this build cannot read is still held")
    func unreadableConnectionKeepsItsKey() {
        let unreadable = UUID()
        let keys = [unreadable: "KEY A", UUID(): "KEY B"]

        #expect(PastedSSHKeyMigration.keysStillHeld(keys, by: [], orUnreadable: [unreadable]) == [unreadable: "KEY A"])
    }

    @Test("Only keys whose connection still has SSH settings are still held")
    func keysStillHeld() {
        let kept = tunnelled()
        let plain = DatabaseConnection(name: "Local", type: .mysql)
        let keys = [kept.id: "KEY A", plain.id: "KEY B", UUID(): "KEY C"]

        #expect(PastedSSHKeyMigration.keysStillHeld(keys, by: [kept, plain]) == [kept.id: "KEY A"])
    }
}
