import Foundation
@_exported import TableProCoreTypes

public struct DatabaseConnection: Identifiable, Hashable, Sendable {
    public static let connectTimeoutSecondsKey = "connectTimeoutSeconds"
    public static let queryTimeoutSecondsKey = "queryTimeoutSeconds"
    public static let connectTimeoutSecondsRange = 1 ... 600
    public static let queryTimeoutSecondsRange = 0 ... Int(Int32.max) / 1_000

    public var id: UUID
    public var name: String
    public var type: DatabaseType
    public var host: String
    public var port: Int
    public var username: String
    public var database: String
    /// The connection's colour, the same enum `ConnectionGroup` and `ConnectionTag` already use.
    ///
    /// This was `colorTag: String?` holding free-form hex, which synced on its own CloudKit field
    /// and meant a colour set on one platform was invisible on the other.
    public var color: ConnectionColor
    /// An SF Symbol the user picked to draw instead of the engine icon. Nil draws the engine icon.
    public var iconName: String?
    public var isReadOnly: Bool
    public var safeModeLevel: SafeModeLevel
    public var queryTimeoutSeconds: Int?
    public var additionalFields: [String: String]

    public var connectTimeoutSeconds: Int? {
        get {
            guard let value = additionalFields[Self.connectTimeoutSecondsKey].flatMap(Int.init),
                  Self.connectTimeoutSecondsRange.contains(value)
            else { return nil }
            return value
        }
        set {
            if let newValue, Self.connectTimeoutSecondsRange.contains(newValue) {
                additionalFields[Self.connectTimeoutSecondsKey] = String(newValue)
            } else {
                additionalFields.removeValue(forKey: Self.connectTimeoutSecondsKey)
            }
        }
    }

    public var sshEnabled: Bool
    public var sshConfiguration: SSHConfiguration?

    public var sslEnabled: Bool
    public var sslConfiguration: SSLConfiguration?

    public var groupId: UUID?
    public var tagIds: [UUID]
    public var sortOrder: Int
    public var isFavorite: Bool
    public var isSample: Bool

    public var participatesInSync: Bool {
        !isSample
    }

    public var tagId: UUID? {
        get { tagIds.first }
        set { tagIds = newValue.map { [$0] } ?? [] }
    }

    public init(
        id: UUID = UUID(),
        name: String = "",
        type: DatabaseType = .mysql,
        host: String = "127.0.0.1",
        port: Int = 3_306,
        username: String = "",
        database: String = "",
        color: ConnectionColor = .none,
        iconName: String? = nil,
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
        sortOrder: Int = 0,
        isFavorite: Bool = false,
        isSample: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.database = database
        self.color = color
        self.iconName = iconName
        self.isReadOnly = isReadOnly
        self.safeModeLevel = safeModeLevel
        self.queryTimeoutSeconds = queryTimeoutSeconds.flatMap {
            Self.queryTimeoutSecondsRange.contains($0) ? $0 : nil
        }
        self.additionalFields = additionalFields
        self.sshEnabled = sshEnabled
        self.sshConfiguration = sshConfiguration
        self.sslEnabled = sslEnabled
        self.sslConfiguration = sslConfiguration
        self.groupId = groupId
        self.tagIds = tagIds
        self.sortOrder = sortOrder
        self.isFavorite = isFavorite
        self.isSample = isSample
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, host, port, username, database, color, colorTag, iconName
        case isReadOnly, safeModeLevel, queryTimeoutSeconds, additionalFields
        case sshEnabled, sshConfiguration, sslEnabled, sslConfiguration
        case groupId, tagId, tagIds, sortOrder, isFavorite, isSample
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
        if let decodedColor = try container.decodeIfPresent(ConnectionColor.self, forKey: .color) {
            color = decodedColor
        } else if let legacyTag = try container.decodeIfPresent(String.self, forKey: .colorTag) {
            color = ConnectionColor(storedValue: legacyTag)
        } else {
            color = .none
        }
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
        isReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        if let level = try container.decodeIfPresent(SafeModeLevel.self, forKey: .safeModeLevel) {
            safeModeLevel = level
        } else {
            safeModeLevel = isReadOnly ? .readOnly : .off
        }
        queryTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .queryTimeoutSeconds)
            .flatMap { Self.queryTimeoutSecondsRange.contains($0) ? $0 : nil }
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
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isSample = try container.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
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
        try container.encode(color, forKey: .color)
        try container.encodeIfPresent(iconName, forKey: .iconName)
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
        try container.encode(isFavorite, forKey: .isFavorite)
        if isSample {
            try container.encode(isSample, forKey: .isSample)
        }
    }
}
