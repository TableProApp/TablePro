import Foundation

/// The format 1 file shape, kept frozen: the only place a v1 file is read.
enum ConnectionBundleV1 {
    struct Envelope: Decodable {
        let formatVersion: Int
        let exportedAt: Date
        let appVersion: String
        let connections: [Connection]
        let groups: [Group]?
        let tags: [Tag]?
        let credentials: [String: ExportableCredentials]?
        let credentialProfiles: [CredentialProfile]?

        /// Connection `i` becomes ref "i", so the index-keyed credentials carry over. `sshProfileName` is never read.
        func upgraded() throws -> ConnectionBundle {
            let groupColors = ConnectionBundleV1.firstValues((groups ?? []).map { (name: $0.name, value: $0.color) })
            let groupIcons = ConnectionBundleV1.firstValues((groups ?? []).map { (name: $0.name, value: $0.iconName) })
            let tagColors = ConnectionBundleV1.firstValues((tags ?? []).map { (name: $0.name, value: $0.color) })
            var profilesByName: [String: CredentialProfile] = [:]
            for profile in credentialProfiles ?? [] where profilesByName[ConnectionBundleV1.key(profile.name)] == nil {
                profilesByName[ConnectionBundleV1.key(profile.name)] = profile
            }

            var builder = ConnectionBundleBuilder(appVersion: appVersion, exportedAt: exportedAt)
            for (index, connection) in connections.enumerated() {
                let ref = BundleRef(String(index))
                let groupPath = connection.groupName.map { name in
                    [ConnectionBundleBuilder.GroupComponent(
                        name: name,
                        color: groupColors[ConnectionBundleV1.key(name)],
                        iconName: groupIcons[ConnectionBundleV1.key(name)]
                    )]
                } ?? []
                let tagNames = connection.tagNames ?? connection.tagName.map { [$0] } ?? []
                let profile = connection.credentialProfileName.flatMap { profilesByName[ConnectionBundleV1.key($0)] }
                builder.addConnection(
                    connection.settings,
                    ref: ref,
                    groupPath: groupPath,
                    tags: tagNames.map { BundleTag(name: $0, color: tagColors[ConnectionBundleV1.key($0)]) },
                    credentialProfile: profile.map {
                        ConnectionBundleBuilder.ProfileSpec(
                            name: $0.name,
                            username: $0.username,
                            passwordMode: BundlePasswordMode(rawValue: $0.passwordMode) ?? .prompt,
                            secureFieldIds: $0.secureFieldIds ?? []
                        )
                    },
                    credentials: credentials?[ref.rawValue]
                )
            }
            return try builder.build()
        }
    }

    struct Connection: Decodable {
        let settings: ExportableConnection
        let groupName: String?
        let tagName: String?
        let tagNames: [String]?
        let credentialProfileName: String?

        private enum CodingKeys: String, CodingKey {
            case groupName, tagName, tagNames, credentialProfileName
        }

        init(from decoder: any Decoder) throws {
            settings = try ExportableConnection(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
            tagName = try container.decodeIfPresent(String.self, forKey: .tagName)
            tagNames = try container.decodeIfPresent([String].self, forKey: .tagNames)
            credentialProfileName = try container.decodeIfPresent(String.self, forKey: .credentialProfileName)
        }
    }

    struct Group: Decodable {
        let name: String
        let color: String?
        let iconName: String?
    }

    struct Tag: Decodable {
        let name: String
        let color: String?
    }

    struct CredentialProfile: Decodable {
        let name: String
        let username: String
        let passwordMode: String
        let secureFieldIds: [String]?
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func firstValues(_ entries: [(name: String, value: String?)]) -> [String: String] {
        var values: [String: String] = [:]
        for entry in entries {
            guard let value = entry.value, values[key(entry.name)] == nil else { continue }
            values[key(entry.name)] = value
        }
        return values
    }
}
