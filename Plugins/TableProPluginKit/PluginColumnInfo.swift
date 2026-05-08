import Foundation

public struct PluginColumnInfo: Codable, Sendable {
    public let name: String
    public let dataType: String
    public let isNullable: Bool
    public let isPrimaryKey: Bool
    public let defaultValue: String?
    public let extra: String?
    public let charset: String?
    public let collation: String?
    public let comment: String?
    public let isIdentity: Bool
    public let identityKind: String?
    public let isGenerated: Bool

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        defaultValue: String? = nil,
        extra: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        comment: String? = nil,
        isIdentity: Bool = false,
        identityKind: String? = nil,
        isGenerated: Bool = false
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
        self.extra = extra
        self.charset = charset
        self.collation = collation
        self.comment = comment
        self.isIdentity = isIdentity
        self.identityKind = identityKind
        self.isGenerated = isGenerated
    }
}
