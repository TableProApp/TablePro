import Foundation

public struct PluginTableMetadata: Codable, Sendable {
    public let tableName: String
    public let dataSize: Int64?
    public let indexSize: Int64?
    public let totalSize: Int64?
    public let avgRowLength: Int64?
    public let rowCount: Int64?
    public let comment: String?
    public let engine: String?
    public let collation: String?
    public let createTime: Date?
    public let updateTime: Date?

    /// Per-engine properties the app does not model: owner, tablespace, persistence, row format.
    /// The driver names and orders them, and they are rendered verbatim.
    public let attributes: [PluginObjectAttribute]

    /// Whether the comment on *this* relation can be written back, as opposed to whether the engine
    /// has table comments at all, which is the separate per-engine gate.
    ///
    /// True unless a driver says otherwise, so a driver that cannot establish the relation kind, and
    /// an already-built plugin that predates this field, both present the comment read-only rather
    /// than offering an edit that resolves to the wrong `COMMENT ON` keyword. PostgreSQL lowers it
    /// from `pg_class.relkind`, which is the only thing separating an ordinary table from a view, a
    /// materialized view or a foreign table once a tab has been opened on it.
    public let commentIsReadOnly: Bool

    public init(
        tableName: String,
        dataSize: Int64? = nil,
        indexSize: Int64? = nil,
        totalSize: Int64? = nil,
        avgRowLength: Int64? = nil,
        rowCount: Int64? = nil,
        comment: String? = nil,
        engine: String? = nil,
        collation: String? = nil,
        createTime: Date? = nil,
        updateTime: Date? = nil,
        attributes: [PluginObjectAttribute],
        commentIsReadOnly: Bool = true
    ) {
        self.tableName = tableName
        self.dataSize = dataSize
        self.indexSize = indexSize
        self.totalSize = totalSize
        self.avgRowLength = avgRowLength
        self.rowCount = rowCount
        self.comment = comment
        self.engine = engine
        self.collation = collation
        self.createTime = createTime
        self.updateTime = updateTime
        self.attributes = attributes
        self.commentIsReadOnly = commentIsReadOnly
    }

    /// Kept at its exact original signature. Adding `attributes:` to it would replace the mangled
    /// symbol and break every plugin already built against it.
    @_disfavoredOverload
    public init(
        tableName: String,
        dataSize: Int64? = nil,
        indexSize: Int64? = nil,
        totalSize: Int64? = nil,
        avgRowLength: Int64? = nil,
        rowCount: Int64? = nil,
        comment: String? = nil,
        engine: String? = nil,
        collation: String? = nil,
        createTime: Date? = nil,
        updateTime: Date? = nil
    ) {
        self.tableName = tableName
        self.dataSize = dataSize
        self.indexSize = indexSize
        self.totalSize = totalSize
        self.avgRowLength = avgRowLength
        self.rowCount = rowCount
        self.comment = comment
        self.engine = engine
        self.collation = collation
        self.createTime = createTime
        self.updateTime = updateTime
        self.attributes = []
        self.commentIsReadOnly = true
    }

    /// Written out because Swift's synthesized `Decodable` does not fall back to an initializer's
    /// default value: a payload encoded before `attributes` existed throws `keyNotFound` instead.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tableName = try container.decode(String.self, forKey: .tableName)
        dataSize = try container.decodeIfPresent(Int64.self, forKey: .dataSize)
        indexSize = try container.decodeIfPresent(Int64.self, forKey: .indexSize)
        totalSize = try container.decodeIfPresent(Int64.self, forKey: .totalSize)
        avgRowLength = try container.decodeIfPresent(Int64.self, forKey: .avgRowLength)
        rowCount = try container.decodeIfPresent(Int64.self, forKey: .rowCount)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        collation = try container.decodeIfPresent(String.self, forKey: .collation)
        createTime = try container.decodeIfPresent(Date.self, forKey: .createTime)
        updateTime = try container.decodeIfPresent(Date.self, forKey: .updateTime)
        attributes = try container.decodeIfPresent([PluginObjectAttribute].self, forKey: .attributes) ?? []
        commentIsReadOnly = try container.decodeIfPresent(Bool.self, forKey: .commentIsReadOnly) ?? true
    }
}
