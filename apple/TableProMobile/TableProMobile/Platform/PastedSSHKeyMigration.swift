import Foundation
import TableProConnectionLibrary
import TableProModels

nonisolated enum PastedSSHKeyMigration {
    private static let idKey = "id"
    private static let sshConfigurationKey = "sshConfiguration"
    private static let privateKeyDataKey = "privateKeyData"

    static func pendingKeys(inLibraryFile data: Data) -> [UUID: String] {
        guard let entries = try? LibraryFileRecords<LegacyConnection>(decoding: data).elements else { return [:] }
        var keys: [UUID: String] = [:]
        for entry in entries {
            guard let key = entry.privateKeyData, !key.isEmpty, keys[entry.id] == nil else { continue }
            keys[entry.id] = key
        }
        return keys
    }

    // A record this build cannot read keeps its key until the key reaches the Keychain.
    static func keysStillHeld(
        _ keys: [UUID: String],
        by connections: [DatabaseConnection],
        orUnreadable unreadableIds: Set<UUID> = []
    ) -> [UUID: String] {
        guard !keys.isEmpty else { return [:] }
        let holders = Set(connections.filter { $0.sshConfiguration != nil }.map(\.id)).union(unreadableIds)
        return keys.filter { holders.contains($0.key) }
    }

    static func libraryFile(_ encoded: Data, keeping keys: [UUID: String]) throws -> Data {
        guard !keys.isEmpty,
              var entries = try JSONSerialization.jsonObject(with: encoded) as? [Any] else {
            return encoded
        }
        for index in entries.indices {
            guard var entry = entries[index] as? [String: Any],
                  let idString = entry[idKey] as? String,
                  let id = UUID(uuidString: idString),
                  let key = keys[id],
                  var ssh = entry[sshConfigurationKey] as? [String: Any] else { continue }
            ssh[privateKeyDataKey] = key
            entry[sshConfigurationKey] = ssh
            entries[index] = entry
        }
        return try JSONSerialization.data(withJSONObject: entries)
    }

    nonisolated private struct LegacyConnection: Decodable {
        let id: UUID
        let privateKeyData: String?

        private enum CodingKeys: String, CodingKey {
            case id, sshConfiguration
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            let ssh = try? container.decodeIfPresent(LegacySSHConfiguration.self, forKey: .sshConfiguration)
            privateKeyData = ssh?.privateKeyData
        }
    }

    nonisolated private struct LegacySSHConfiguration: Decodable {
        let privateKeyData: String?

        private enum CodingKeys: String, CodingKey {
            case privateKeyData
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            privateKeyData = try? container.decodeIfPresent(String.self, forKey: .privateKeyData)
        }
    }
}
