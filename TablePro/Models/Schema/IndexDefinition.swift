//
//  IndexDefinition.swift
//  TablePro
//
//  Represents an index definition for schema editing.
//

import Foundation
import TableProPluginKit

/// Index definition for schema modification (editable structure tab)
struct EditableIndexDefinition: Hashable, Codable, Identifiable {
    var id: UUID
    var name: String
    var columns: [String]
    var type: IndexType
    var isUnique: Bool
    var isPrimary: Bool
    var comment: String?
    var columnPrefixes: [String: Int]
    var whereClause: String?
    /// The entries of `columns` that are expressions, such as `lower(email)`, rather than column names.
    var expressions: [String]
    /// The columns stored beside the key and written as `INCLUDE`, which are not part of the key.
    var includedColumns: [String]

    /// The server's own spellings of the method and key list and of `whereClause` for a
    /// `CREATE INDEX`, carried from the catalog read.
    ///
    /// The method and key spelling applies only while `type`, `columns`, `expressions` and
    /// `includedColumns` still hold what they were read with, and the predicate spelling only while
    /// `whereClause` does. So a rename keeps both, an edit to the condition keeps the keys, and an
    /// edit to the columns or the type writes the index from its fields. The pairs are stored rather
    /// than cleared on edit, so changing a field and changing it back restores the spelling.
    ///
    /// Not encoded. An index pasted from the clipboard can come from another connection, where
    /// `public.gin_trgm_ops` names a schema this one may not have.
    var ddlMethodAndKeys: String? { catalogKeys?.spelling(for: keyShape) }
    var ddlWhereClause: String? { catalogPredicate?.spelling(for: whereClause) }

    private var catalogKeys: CatalogSpelling<KeyShape>?
    private var catalogPredicate: CatalogSpelling<String>?

    private struct KeyShape: Hashable {
        let type: IndexType
        let columns: [String]
        let expressions: [String]
        let includedColumns: [String]
    }

    private var keyShape: KeyShape {
        KeyShape(type: type, columns: columns, expressions: expressions, includedColumns: includedColumns)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, columns, type, isUnique, isPrimary, comment, columnPrefixes, whereClause
        case expressions, includedColumns
    }

    enum IndexType: String, Codable, CaseIterable {
        case btree = "BTREE"
        case hash = "HASH"
        case fulltext = "FULLTEXT"
        case spatial = "SPATIAL"  // MySQL only
        case gin = "GIN"          // PostgreSQL only
        case gist = "GIST"        // PostgreSQL only
        case brin = "BRIN"        // PostgreSQL only
    }

    init(
        id: UUID,
        name: String,
        columns: [String],
        type: IndexType,
        isUnique: Bool,
        isPrimary: Bool,
        comment: String?,
        columnPrefixes: [String: Int] = [:],
        whereClause: String? = nil,
        expressions: [String] = [],
        includedColumns: [String] = [],
        ddlMethodAndKeys: String? = nil,
        ddlWhereClause: String? = nil
    ) {
        self.id = id
        self.name = name
        self.columns = columns
        self.type = type
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.comment = comment
        self.columnPrefixes = columnPrefixes
        self.whereClause = whereClause
        self.expressions = expressions
        self.includedColumns = includedColumns
        let shape = KeyShape(type: type, columns: columns, expressions: expressions, includedColumns: includedColumns)
        self.catalogKeys = ddlMethodAndKeys.map { CatalogSpelling(value: shape, spelling: $0) }
        if let whereClause, let ddlWhereClause {
            self.catalogPredicate = CatalogSpelling(value: whereClause, spelling: ddlWhereClause)
        }
    }

    /// `expressions` and `includedColumns` are read only if present, so an index copied by a build
    /// that predates them still pastes.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            columns: try container.decode([String].self, forKey: .columns),
            type: try container.decode(IndexType.self, forKey: .type),
            isUnique: try container.decode(Bool.self, forKey: .isUnique),
            isPrimary: try container.decode(Bool.self, forKey: .isPrimary),
            comment: try container.decodeIfPresent(String.self, forKey: .comment),
            columnPrefixes: try container.decode([String: Int].self, forKey: .columnPrefixes),
            whereClause: try container.decodeIfPresent(String.self, forKey: .whereClause),
            expressions: try container.decodeIfPresent([String].self, forKey: .expressions) ?? [],
            includedColumns: try container.decodeIfPresent([String].self, forKey: .includedColumns) ?? []
        )
    }

    /// For an index said again in another engine's words, where none of this server's spellings name
    /// anything the target has.
    mutating func dropCatalogSpellings() {
        catalogKeys = nil
        catalogPredicate = nil
    }

    /// The column names the table must have for this index: its key columns that are not expressions,
    /// then its `INCLUDE` columns.
    var referencedColumnNames: [String] {
        columns.filter { !expressions.contains($0) } + includedColumns
    }

    /// Create a placeholder index for adding new indexes
    static func placeholder() -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(),
            name: "",
            columns: [],
            type: .btree,
            isUnique: false,
            isPrimary: false,
            comment: nil,
            columnPrefixes: [:],
            whereClause: nil
        )
    }

    /// Check if this definition is valid (not a placeholder)
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            !columns.isEmpty
    }

    /// Create from existing IndexInfo
    static func from(_ indexInfo: IndexInfo) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: indexInfo.id,
            name: indexInfo.name,
            columns: indexInfo.columns,
            type: IndexType(rawValue: indexInfo.type.uppercased()) ?? .btree,
            isUnique: indexInfo.isUnique,
            isPrimary: indexInfo.isPrimary,
            comment: nil,
            columnPrefixes: indexInfo.columnPrefixes ?? [:],
            whereClause: indexInfo.whereClause,
            expressions: indexInfo.expressions ?? [],
            includedColumns: indexInfo.includedColumns ?? [],
            ddlMethodAndKeys: indexInfo.ddlMethodAndKeys,
            ddlWhereClause: indexInfo.ddlWhereClause
        )
    }

    func toPlugin() -> PluginIndexDefinition {
        PluginIndexDefinition(
            name: name, columns: columns, isUnique: isUnique, indexType: type.rawValue,
            columnPrefixes: columnPrefixes.isEmpty ? nil : columnPrefixes,
            whereClause: whereClause,
            expressions: expressions.isEmpty ? nil : expressions,
            includedColumns: includedColumns.isEmpty ? nil : includedColumns,
            ddlMethodAndKeys: ddlMethodAndKeys,
            ddlWhereClause: ddlWhereClause
        )
    }

    /// Convert back to IndexInfo
    func toIndexInfo() -> IndexInfo {
        IndexInfo(
            name: name,
            columns: columns,
            isUnique: isUnique,
            isPrimary: isPrimary,
            type: type.rawValue,
            columnPrefixes: columnPrefixes.isEmpty ? nil : columnPrefixes,
            whereClause: whereClause,
            expressions: expressions.isEmpty ? nil : expressions,
            includedColumns: includedColumns.isEmpty ? nil : includedColumns,
            ddlMethodAndKeys: ddlMethodAndKeys,
            ddlWhereClause: ddlWhereClause
        )
    }

    /// A copy under a fresh identity, for paste and duplicate. Assigning `id` rather than
    /// re-listing every property is what stops a newly added field being silently dropped here.
    func withNewIdentity() -> EditableIndexDefinition {
        var copy = self
        copy.id = UUID()
        return copy
    }

    /// A copy under a fresh identity for a paste into a table on `target`, copied from a table on
    /// `source`.
    ///
    /// Expressions and `INCLUDE` columns are the source engine's SQL, and a writer for another engine
    /// cannot say either: it quotes an expression as a column name, which the server refuses on save,
    /// and leaves `INCLUDE` out without a word. So a paste that crosses engines, on the line Copy To
    /// draws with `SQLTypeFamily.needsTranslation`, keeps each expression as a plain entry that the
    /// column check names before anything runs, and leaves the `INCLUDE` columns behind as Copy To
    /// does. A `nil` source is a copy made by a build that wrote neither field.
    func pasted(from source: DatabaseType?, into target: DatabaseType) -> EditableIndexDefinition {
        var copy = withNewIdentity()
        if let source, !SQLTypeFamily.needsTranslation(from: source, to: target) {
            return copy
        }
        copy.expressions = []
        copy.includedColumns = []
        return copy
    }
}
