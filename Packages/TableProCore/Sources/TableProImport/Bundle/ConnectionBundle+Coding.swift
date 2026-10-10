import Foundation

/// The settings keys and these link keys share one JSON object, so `ExportableConnection` must never declare them.
extension BundleConnection: Codable {
    private enum LinkKeys: String, CodingKey {
        case ref, groupRef, tagNames, credentialProfileRef
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LinkKeys.self)
        self.init(
            ref: try container.decode(BundleRef.self, forKey: .ref),
            settings: try ExportableConnection(from: decoder),
            groupRef: try container.decodeIfPresent(BundleRef.self, forKey: .groupRef),
            tagNames: try container.decodeIfPresent([String].self, forKey: .tagNames) ?? [],
            credentialProfileRef: try container.decodeIfPresent(BundleRef.self, forKey: .credentialProfileRef)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try settings.encode(to: encoder)
        var container = encoder.container(keyedBy: LinkKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encodeIfPresent(groupRef, forKey: .groupRef)
        if !tagNames.isEmpty {
            try container.encode(tagNames, forKey: .tagNames)
        }
        try container.encodeIfPresent(credentialProfileRef, forKey: .credentialProfileRef)
    }
}

extension BundleCredentialProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case ref, name, username, passwordMode, secureFieldIds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ref: try container.decode(BundleRef.self, forKey: .ref),
            name: try container.decode(String.self, forKey: .name),
            username: try container.decode(String.self, forKey: .username),
            passwordMode: try container.decodeIfPresent(BundlePasswordMode.self, forKey: .passwordMode) ?? .prompt,
            secureFieldIds: try container.decodeIfPresent([String].self, forKey: .secureFieldIds) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(name, forKey: .name)
        try container.encode(username, forKey: .username)
        try container.encode(passwordMode, forKey: .passwordMode)
        if !secureFieldIds.isEmpty {
            try container.encode(secureFieldIds, forKey: .secureFieldIds)
        }
    }
}

enum ConnectionBundleKey: String, CodingKey {
    case formatVersion, exportedAt, appVersion, connections, groups, tags
    case credentialProfiles, credentials, queryFolders, savedQueries
}

/// An older build decodes this with its own v1 types and then reports the version, so the header keys and
/// `connections` are always written.
extension ConnectionBundle: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ConnectionBundleKey.self)
        try container.encode(Self.formatVersion, forKey: .formatVersion)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(connections, forKey: .connections)
        try container.encodeUnlessEmpty(groups, forKey: .groups)
        try container.encodeUnlessEmpty(tags, forKey: .tags)
        try container.encodeUnlessEmpty(credentialProfiles, forKey: .credentialProfiles)
        try container.encodeUnlessEmpty(queryFolders, forKey: .queryFolders)
        try container.encodeUnlessEmpty(savedQueries, forKey: .savedQueries)
        if !credentials.isEmpty {
            let keyed = Dictionary(uniqueKeysWithValues: credentials.map { ($0.key.rawValue, $0.value) })
            try container.encode(keyed, forKey: .credentials)
        }
    }
}

struct ConnectionBundlePayload: Decodable {
    let exportedAt: Date
    let appVersion: String
    let connections: [BundleConnection]
    let groups: [BundleGroup]
    let tags: [BundleTag]
    let credentialProfiles: [BundleCredentialProfile]
    let credentials: [BundleRef: ExportableCredentials]
    let queryFolders: [BundleQueryFolder]
    let savedQueries: [BundleSavedQuery]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ConnectionBundleKey.self)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        connections = try container.decode([BundleConnection].self, forKey: .connections)
        groups = try container.decodeIfPresent([BundleGroup].self, forKey: .groups) ?? []
        tags = try container.decodeIfPresent([BundleTag].self, forKey: .tags) ?? []
        credentialProfiles = try container.decodeIfPresent([BundleCredentialProfile].self, forKey: .credentialProfiles) ?? []
        queryFolders = try container.decodeIfPresent([BundleQueryFolder].self, forKey: .queryFolders) ?? []
        savedQueries = try container.decodeIfPresent([BundleSavedQuery].self, forKey: .savedQueries) ?? []
        let keyed = try container.decodeIfPresent([String: ExportableCredentials].self, forKey: .credentials) ?? [:]
        credentials = Dictionary(uniqueKeysWithValues: keyed.map { (BundleRef($0.key), $0.value) })
    }

    func bundle(sanitizing transform: (ExportableConnection) -> ExportableConnection) throws -> ConnectionBundle {
        try ConnectionBundle(
            exportedAt: exportedAt,
            appVersion: appVersion,
            connections: connections.map { connection in
                var copy = connection
                copy.settings = transform(connection.settings)
                return copy
            },
            groups: groups,
            tags: tags,
            credentialProfiles: credentialProfiles,
            credentials: credentials,
            queryFolders: queryFolders,
            savedQueries: savedQueries
        )
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeUnlessEmpty<Element: Encodable>(_ values: [Element], forKey key: Key) throws {
        guard !values.isEmpty else { return }
        try encode(values, forKey: key)
    }
}
