import Foundation
@_exported import TableProCoreTypes

public struct DatabaseConnection: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var type: DatabaseType
    public var host: String
    public var port: Int
    public var username: String
    public var database: String
    public var colorTag: String?
    public var isReadOnly: Bool
    public var safeModeLevel: SafeModeLevel
    public var queryTimeoutSeconds: Int?
    public var additionalFields: [String: String]

    public var sshEnabled: Bool
    public var sshConfiguration: SSHConfiguration?

    public var sslEnabled: Bool
    public var sslConfiguration: SSLConfiguration?

    public var groupId: UUID?
    public var tagIds: [UUID]
    public var sortOrder: Int

    public var tagId: UUID? {
        get { tagIds.first }
        set { tagIds = newValue.map { [$0] } ?? [] }
    }

    public init(
        id: UUID = UUID(),
        name: String = "",
        type: DatabaseType = .mysql,
        host: String = "127.0.0.1",
        port: Int = 3306,
        username: String = "",
        database: String = "",
        colorTag: String? = nil,
        isReadOnly: Bool = false,
        safeModeLevel: SafeModeLevel = .off,
        queryTimeoutSeconds: Int? = nil,
        additionalFields: [String: String] = [:],
        sshEnabled: Bool = false,
        sshConfiguration: SSHConfiguration? = nil,
        sslEnabled: Bool = false,
        sslConfiguration: SSLConfiguration? = nil,
        groupId: UUID? = nil,
        tagIds: [UUID] = [],
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.database = database
        self.colorTag = colorTag
        self.isReadOnly = isReadOnly
        self.safeModeLevel = safeModeLevel
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.additionalFields = additionalFields
        self.sshEnabled = sshEnabled
        self.sshConfiguration = sshConfiguration
        self.sslEnabled = sslEnabled
        self.sslConfiguration = sslConfiguration
        self.groupId = groupId
        self.tagIds = tagIds
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, host, port, username, database, colorTag
        case isReadOnly, safeModeLevel, queryTimeoutSeconds, additionalFields
        case sshEnabled, sshConfiguration, sslEnabled, sslConfiguration
        case groupId, tagId, tagIds, sortOrder
    }
}

extension DatabaseConnection: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(DatabaseType.self, forKey: .type)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        database = try container.decode(String.self, forKey: .database)
        colorTag = try container.decodeIfPresent(String.self, forKey: .colorTag)
        isReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        if let level = try container.decodeIfPresent(SafeModeLevel.self, forKey: .safeModeLevel) {
            safeModeLevel = level
        } else {
            safeModeLevel = isReadOnly ? .readOnly : .off
        }
        queryTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .queryTimeoutSeconds)
        additionalFields = try container.decodeIfPresent([String: String].self, forKey: .additionalFields) ?? [:]
        sshEnabled = try container.decodeIfPresent(Bool.self, forKey: .sshEnabled) ?? false
        sshConfiguration = try container.decodeIfPresent(SSHConfiguration.self, forKey: .sshConfiguration)
        sslEnabled = try container.decodeIfPresent(Bool.self, forKey: .sslEnabled) ?? false
        sslConfiguration = try container.decodeIfPresent(SSLConfiguration.self, forKey: .sslConfiguration)
        groupId = try container.decodeIfPresent(UUID.self, forKey: .groupId)
        let decodedTagIds = try container.decodeIfPresent([UUID].self, forKey: .tagIds) ?? []
        if decodedTagIds.isEmpty {
            tagIds = try container.decodeIfPresent(UUID.self, forKey: .tagId).map { [$0] } ?? []
        } else {
            tagIds = decodedTagIds
        }
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(database, forKey: .database)
        try container.encodeIfPresent(colorTag, forKey: .colorTag)
        try container.encode(isReadOnly, forKey: .isReadOnly)
        try container.encode(safeModeLevel, forKey: .safeModeLevel)
        try container.encodeIfPresent(queryTimeoutSeconds, forKey: .queryTimeoutSeconds)
        try container.encode(additionalFields, forKey: .additionalFields)
        try container.encode(sshEnabled, forKey: .sshEnabled)
        try container.encodeIfPresent(sshConfiguration, forKey: .sshConfiguration)
        try container.encode(sslEnabled, forKey: .sslEnabled)
        try container.encodeIfPresent(sslConfiguration, forKey: .sslConfiguration)
        try container.encodeIfPresent(groupId, forKey: .groupId)
        if !tagIds.isEmpty {
            try container.encode(tagIds, forKey: .tagIds)
        }
        try container.encode(sortOrder, forKey: .sortOrder)
    }
}
