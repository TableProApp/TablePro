import Foundation

/// The format 1 file shape, kept frozen: the only place a v1 file is read or written. Builds before format 2
/// read nothing else, so a bundle that fits it is written in it.
enum ConnectionBundleV1 {
    static let formatVersion = 1

    struct Envelope: Codable {
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

    struct Connection: Codable {
        let settings: ExportableConnection
        let groupName: String?
        let tagName: String?
        let tagNames: [String]?
        let credentialProfileName: String?

        private enum CodingKeys: String, CodingKey {
            case groupName, tagName, tagNames, credentialProfileName
        }

        /// `tagName` repeats the first tag for builds that read only it.
        init(settings: ExportableConnection, groupName: String?, tagNames: [String], credentialProfileName: String?) {
            self.settings = settings
            self.groupName = groupName
            self.tagName = tagNames.first
            self.tagNames = tagNames.isEmpty ? nil : tagNames
            self.credentialProfileName = credentialProfileName
        }

        init(from decoder: any Decoder) throws {
            settings = try ExportableConnection(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
            tagName = try container.decodeIfPresent(String.self, forKey: .tagName)
            tagNames = try container.decodeIfPresent([String].self, forKey: .tagNames)
            credentialProfileName = try container.decodeIfPresent(String.self, forKey: .credentialProfileName)
        }

        func encode(to encoder: any Encoder) throws {
            try settings.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(groupName, forKey: .groupName)
            try container.encodeIfPresent(tagName, forKey: .tagName)
            try container.encodeIfPresent(tagNames, forKey: .tagNames)
            try container.encodeIfPresent(credentialProfileName, forKey: .credentialProfileName)
        }
    }

    struct Group: Codable {
        let name: String
        let color: String?
        let iconName: String?
    }

    struct Tag: Codable {
        let name: String
        let color: String?
    }

    struct CredentialProfile: Codable {
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

extension ConnectionBundleV1.Envelope {
    /// Nil unless the envelope reads back as the same bundle, connection `i` as ref "i". Saved queries, query
    /// folders, a group inside a group, and names that differ only in case fail that, and so does any field
    /// format 2 gains later, so format 1 never drops what format 2 keeps.
    init?(_ bundle: ConnectionBundle) {
        var credentials: [String: ExportableCredentials] = [:]
        for (index, connection) in bundle.connections.enumerated() {
            credentials[String(index)] = bundle.credentials[connection.ref]
        }
        let envelope = Self(
            formatVersion: ConnectionBundleV1.formatVersion,
            exportedAt: bundle.exportedAt,
            appVersion: bundle.appVersion,
            connections: bundle.connections.map { connection in
                ConnectionBundleV1.Connection(
                    settings: connection.settings,
                    groupName: bundle.groupChain(connection.groupRef).last?.name,
                    tagNames: connection.tagNames,
                    credentialProfileName: bundle.credentialProfile(connection.credentialProfileRef)?.name
                )
            },
            groups: bundle.groups.isEmpty ? nil : bundle.groups.map {
                ConnectionBundleV1.Group(name: $0.name, color: $0.color, iconName: $0.iconName)
            },
            tags: bundle.tags.isEmpty ? nil : bundle.tags.map { ConnectionBundleV1.Tag(name: $0.name, color: $0.color) },
            credentials: credentials.isEmpty ? nil : credentials,
            credentialProfiles: bundle.credentialProfiles.isEmpty ? nil : bundle.credentialProfiles.map {
                ConnectionBundleV1.CredentialProfile(
                    name: $0.name,
                    username: $0.username,
                    passwordMode: $0.passwordMode.rawValue,
                    secureFieldIds: $0.secureFieldIds.isEmpty ? nil : $0.secureFieldIds
                )
            }
        )
        let renumbered = ConnectionBundle(
            unchecked: bundle.exportedAt,
            appVersion: bundle.appVersion,
            connections: bundle.connections.enumerated().map { index, connection in
                var copy = connection
                copy.ref = BundleRef(String(index))
                return copy
            },
            groups: bundle.groups,
            tags: bundle.tags,
            credentialProfiles: bundle.credentialProfiles,
            credentials: Dictionary(uniqueKeysWithValues: credentials.map { (BundleRef($0.key), $0.value) }),
            queryFolders: bundle.queryFolders,
            savedQueries: bundle.savedQueries
        )
        guard (try? envelope.upgraded()) == renumbered else { return nil }
        self = envelope
    }
}
