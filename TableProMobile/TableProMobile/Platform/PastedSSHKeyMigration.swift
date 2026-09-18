import Foundation
import TableProModels

nonisolated enum PastedSSHKeyMigration {
    private static let idKey = "id"
    private static let sshConfigurationKey = "sshConfiguration"
    private static let privateKeyDataKey = "privateKeyData"

    static func pendingKeys(inLibraryFile data: Data) -> [UUID: String] {
        guard let entries = try? JSONDecoder().decode([LegacyConnection].self, from: data) else { return [:] }
        var keys: [UUID: String] = [:]
        for entry in entries {
            guard let key = entry.privateKeyData, !key.isEmpty, keys[entry.id] == nil else { continue }
            keys[entry.id] = key
        }
        return keys
    }

    static func keysStillHeld(_ keys: [UUID: String], by connections: [DatabaseConnection]) -> [UUID: String] {
        guard !keys.isEmpty else { return [:] }
        let holders = Set(connections.filter { $0.sshConfiguration != nil }.map(\.id))
        return keys.filter { holders.contains($0.key) }
    }

    static func libraryFile(_ encoded: Data, keeping keys: [UUID: String]) throws -> Data {
        guard !keys.isEmpty,
              var entries = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] else {
            return encoded
        }
        for index in entries.indices {
            guard let idString = entries[index][idKey] as? String,
                  let id = UUID(uuidString: idString),
                  let key = keys[id],
                  var ssh = entries[index][sshConfigurationKey] as? [String: Any] else { continue }
            ssh[privateKeyDataKey] = key
            entries[index][sshConfigurationKey] = ssh
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
