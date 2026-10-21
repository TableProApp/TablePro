import Foundation

public struct PluginTableInfo: Codable, Sendable {
    public let name: String
    public let type: String
    public let rowCount: Int?
    public let schema: String?
    public let comment: String?

    /// How many partitions this table holds, for a table the engine reports as partitioned. Nil
    /// means the engine did not say, which is not the same as zero: a partitioned table with no
    /// partitions yet answers 0.
    ///
    /// It rides the table listing rather than a fetch of its own because a collapsed row has to
    /// show it before anything is expanded, and because it is the only thing that tells a
    /// partitioned MySQL or Oracle table from a plain one.
    public let partitionCount: Int?

    // The column a sequence belongs to, in the sequence's own schema. Nil for anything else.
    public let ownedByTable: String?
    public let ownedByColumn: String?

    public init(
        name: String,
        type: String = "TABLE",
        rowCount: Int? = nil,
        schema: String? = nil,
        comment: String?,
        partitionCount: Int?,
        ownedByTable: String?,
        ownedByColumn: String?
    ) {
        self.name = name
        self.type = type
        self.rowCount = rowCount
        self.schema = schema
        self.comment = comment
        self.partitionCount = partitionCount
        self.ownedByTable = ownedByTable
        self.ownedByColumn = ownedByColumn
    }

    @_disfavoredOverload
    public init(
        name: String,
        type: String = "TABLE",
        rowCount: Int? = nil,
        schema: String? = nil,
        comment: String?,
        partitionCount: Int?
    ) {
        self.name = name
        self.type = type
        self.rowCount = rowCount
        self.schema = schema
        self.comment = comment
        self.partitionCount = partitionCount
        self.ownedByTable = nil
        self.ownedByColumn = nil
    }

    @_disfavoredOverload
    public init(
        name: String,
        type: String = "TABLE",
        rowCount: Int? = nil,
        schema: String? = nil,
        comment: String?
    ) {
        self.name = name
        self.type = type
        self.rowCount = rowCount
        self.schema = schema
        self.comment = comment
        self.partitionCount = nil
        self.ownedByTable = nil
        self.ownedByColumn = nil
    }

    @_disfavoredOverload
    public init(
        name: String,
        type: String = "TABLE",
        rowCount: Int? = nil,
        schema: String? = nil
    ) {
        self.name = name
        self.type = type
        self.rowCount = rowCount
        self.schema = schema
        self.comment = nil
        self.partitionCount = nil
        self.ownedByTable = nil
        self.ownedByColumn = nil
    }
}
