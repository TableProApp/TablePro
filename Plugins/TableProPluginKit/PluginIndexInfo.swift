import Foundation

public struct PluginIndexInfo: Codable, Sendable {
    public let name: String
    /// The index's key parts in key order. A part that is an expression is written the way the server
    /// displays it, and is also listed in `expressions`.
    public let columns: [String]
    public let isUnique: Bool
    public let isPrimary: Bool
    public let type: String
    public let columnPrefixes: [String: Int]?
    public let whereClause: String?
    /// The entries of `columns` that are expressions rather than column names, or nil where the
    /// driver reports none.
    ///
    /// A writer quotes a column name and parenthesises an expression. Reading `lower(email)` as a
    /// column name quotes it into a column that does not exist.
    public let expressions: [String]?
    /// The columns an index stores beside its key without making them part of it, as `INCLUDE`
    /// writes them, or nil where the driver reports none.
    ///
    /// Kept out of `columns` because they are not key parts: `UNIQUE (a) INCLUDE (b)` refuses two rows
    /// sharing `a`, and `UNIQUE (a, b)` accepts them.
    public let includedColumns: [String]?
    /// Everything a `CREATE INDEX` writes between the table and its `WHERE` clause, as this server
    /// spells it, or nil where the driver has nothing more exact than the fields above.
    ///
    /// The fields cannot hold an operator class, a collation, a sort order, `NULLS NOT DISTINCT` or a
    /// storage parameter, so an index rebuilt from them is a different index. This spelling names every
    /// type, operator class and function with its schema wherever the name would not resolve on its
    /// own, so a DDL writer emits it verbatim on a connection whose `search_path` is another schema.
    public let ddlMethodAndKeys: String?
    /// `whereClause` as a `CREATE INDEX` on another schema has to write it, or nil to write
    /// `whereClause`.
    public let ddlWhereClause: String?
    public let isValid: Bool?

    /// The signature published before key expressions, `INCLUDE` columns and the DDL spellings
    /// existed. Kept byte-identical and disfavoured so plugins built against an older PluginKit keep
    /// resolving their own mangled symbol.
    @_disfavoredOverload
    public init(
        name: String,
        columns: [String],
        isUnique: Bool = false,
        isPrimary: Bool = false,
        type: String = "BTREE",
        columnPrefixes: [String: Int]? = nil,
        whereClause: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.type = type
        self.columnPrefixes = columnPrefixes
        self.whereClause = whereClause
        self.expressions = nil
        self.includedColumns = nil
        self.ddlMethodAndKeys = nil
        self.ddlWhereClause = nil
        self.isValid = nil
    }

    @_disfavoredOverload
    public init(
        name: String,
        columns: [String],
        isUnique: Bool = false,
        isPrimary: Bool = false,
        type: String = "BTREE",
        columnPrefixes: [String: Int]? = nil,
        whereClause: String? = nil,
        expressions: [String]?,
        includedColumns: [String]?,
        ddlMethodAndKeys: String?,
        ddlWhereClause: String?
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.type = type
        self.columnPrefixes = columnPrefixes
        self.whereClause = whereClause
        self.expressions = expressions
        self.includedColumns = includedColumns
        self.ddlMethodAndKeys = ddlMethodAndKeys
        self.ddlWhereClause = ddlWhereClause
        self.isValid = nil
    }

    public init(
        name: String,
        columns: [String],
        isUnique: Bool = false,
        isPrimary: Bool = false,
        type: String = "BTREE",
        columnPrefixes: [String: Int]? = nil,
        whereClause: String? = nil,
        expressions: [String]?,
        includedColumns: [String]?,
        ddlMethodAndKeys: String?,
        ddlWhereClause: String?,
        isValid: Bool?
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.type = type
        self.columnPrefixes = columnPrefixes
        self.whereClause = whereClause
        self.expressions = expressions
        self.includedColumns = includedColumns
        self.ddlMethodAndKeys = ddlMethodAndKeys
        self.ddlWhereClause = ddlWhereClause
        self.isValid = isValid
    }
}
