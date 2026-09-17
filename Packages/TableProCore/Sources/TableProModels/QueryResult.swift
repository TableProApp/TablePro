import Foundation
import TableProPluginKit

// MARK: - App-Side Result Types

public struct QueryResult: Sendable {
    public let columns: [ColumnInfo]
    public let rows: [[String?]]
    public let rowsAffected: Int
    public let executionTime: TimeInterval
    public let isTruncated: Bool
    public let statusMessage: String?

    public init(
        columns: [ColumnInfo],
        rows: [[String?]],
        rowsAffected: Int,
        executionTime: TimeInterval,
        isTruncated: Bool = false,
        statusMessage: String? = nil
    ) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.executionTime = executionTime
        self.isTruncated = isTruncated
        self.statusMessage = statusMessage
    }
}

public struct ColumnInfo: Sendable, Identifiable {
    public var id: Int { ordinalPosition }
    public let name: String
    public let typeName: String
    public let isPrimaryKey: Bool
    public let isNullable: Bool
    public let defaultValue: String?
    public let comment: String?
    public let characterMaxLength: Int?
    public let ordinalPosition: Int
    public let isAutoIncrement: Bool
    public let isGenerated: Bool

    public init(
        name: String,
        typeName: String,
        isPrimaryKey: Bool = false,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        comment: String? = nil,
        characterMaxLength: Int? = nil,
        ordinalPosition: Int = 0,
        isAutoIncrement: Bool = false,
        isGenerated: Bool = false
    ) {
        self.name = name
        self.typeName = typeName
        self.isPrimaryKey = isPrimaryKey
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.comment = comment
        self.characterMaxLength = characterMaxLength
        self.ordinalPosition = ordinalPosition
        self.isAutoIncrement = isAutoIncrement
        self.isGenerated = isGenerated
    }
}

public struct TableInfo: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let type: TableKind
    public let rowCount: Int?
    public let dataSize: Int?
    public let comment: String?

    public enum TableKind: String, Sendable, CaseIterable {
        case table
        case view
        case materializedView
        case systemTable
        case externalTable
        case sequence

        public enum ListSection: String, Sendable, CaseIterable {
            case tables
            case views
        }

        /// Which section of the object list a row lands in. Exhaustive so a kind added later
        /// cannot fall through both of the list's filters and vanish from the list entirely,
        /// which is what happened to a MariaDB sequence.
        public var listSection: ListSection {
            switch self {
            case .table, .systemTable, .externalTable, .sequence: return .tables
            case .view, .materializedView: return .views
            }
        }

        /// Measured on MariaDB 11.4.13: `TRUNCATE` on a sequence fails ERROR 1031, and a system
        /// table belongs to the catalog. A view holds no rows of its own.
        public var allowsTruncate: Bool {
            switch self {
            case .table: return true
            case .view, .materializedView, .systemTable, .externalTable, .sequence: return false
            }
        }

        /// `DROP TABLE` on a MariaDB sequence succeeds, measured on 11.4.13. A view needs
        /// `DROP VIEW`, which this list does not write.
        ///
        /// An external table is left out for the same reason it was when it was folded into
        /// `.systemTable`: this list writes one drop statement for every kind it offers, and what
        /// an engine wants for a table whose rows live outside the database is unmeasured here.
        public var allowsDrop: Bool {
            switch self {
            case .table, .sequence: return true
            case .view, .materializedView, .systemTable, .externalTable: return false
            }
        }

        /// Whether the data browser may offer row editing and Insert Row. A sequence takes an
        /// INSERT and refuses UPDATE and DELETE with ERROR 1031, so it is read-only here too.
        ///
        /// An external table reads rows from a catalog outside the database, has no primary key
        /// to target and refuses INSERT, measured as ERROR 1235 on OceanBase CE 4.4.2.1, which is
        /// why the Mac app withholds row editing for one and this must too.
        public var allowsRowEditing: Bool {
            switch self {
            case .table, .systemTable: return true
            case .view, .materializedView, .externalTable, .sequence: return false
            }
        }
    }

    public init(
        name: String,
        type: TableKind = .table,
        rowCount: Int? = nil,
        dataSize: Int? = nil,
        comment: String? = nil
    ) {
        self.name = name
        self.type = type
        self.rowCount = rowCount
        self.dataSize = dataSize
        self.comment = comment
    }
}

public struct IndexInfo: Sendable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let isPrimary: Bool
    public let type: String

    public init(
        name: String,
        columns: [String],
        isUnique: Bool = false,
        isPrimary: Bool = false,
        type: String = "BTREE"
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.type = type
    }
}

public struct ForeignKeyInfo: Sendable {
    public let name: String
    public let column: String
    public let referencedTable: String
    public let referencedColumn: String
    public let referencedSchema: String?
    public let onDelete: String
    public let onUpdate: String

    public init(
        name: String,
        column: String,
        referencedTable: String,
        referencedColumn: String,
        referencedSchema: String? = nil,
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) {
        self.name = name
        self.column = column
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
        self.referencedSchema = referencedSchema
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }
}

public enum ConnectionStatus: Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

public struct DatabaseError: Error, LocalizedError, Sendable {
    public let code: Int?
    public let message: String
    public let sqlState: String?

    public var errorDescription: String? { message }

    public init(code: Int? = nil, message: String, sqlState: String? = nil) {
        self.code = code
        self.message = message
        self.sqlState = sqlState
    }
}

// MARK: - Mapping from Plugin Types

public extension QueryResult {
    init(from plugin: PluginQueryResult) {
        let columnInfos = zip(plugin.columns, plugin.columnTypeNames).enumerated().map { index, pair in
            ColumnInfo(
                name: pair.0,
                typeName: pair.1,
                ordinalPosition: index
            )
        }
        let legacyRows: [[String?]] = plugin.rows.map { row in
            row.map { cell -> String? in
                switch cell {
                case .null: return nil
                case .text(let value): return value
                case .bytes(let data): return data.map { String(format: "%02X", $0) }.joined()
                }
            }
        }
        self.init(
            columns: columnInfos,
            rows: legacyRows,
            rowsAffected: plugin.rowsAffected,
            executionTime: plugin.executionTime,
            isTruncated: plugin.isTruncated,
            statusMessage: plugin.statusMessage
        )
    }
}

public extension TableInfo {
    init(from plugin: PluginTableInfo) {
        let kind: TableKind
        switch plugin.type.uppercased() {
        case "TABLE", "BASE TABLE":
            kind = .table
        case "VIEW":
            kind = .view
        case "MATERIALIZED VIEW":
            kind = .materializedView
        case "SYSTEM TABLE":
            kind = .systemTable
        case "EXTERNAL TABLE":
            kind = .externalTable
        case "SEQUENCE":
            kind = .sequence
        default:
            kind = .table
        }
        self.init(
            name: plugin.name,
            type: kind,
            rowCount: plugin.rowCount
        )
    }
}

public extension ColumnInfo {
    init(from plugin: PluginColumnInfo, ordinalPosition: Int = 0) {
        self.init(
            name: plugin.name,
            typeName: plugin.dataType,
            isPrimaryKey: plugin.isPrimaryKey,
            isNullable: plugin.isNullable,
            defaultValue: plugin.defaultValue,
            comment: plugin.comment,
            ordinalPosition: ordinalPosition,
            isAutoIncrement: plugin.isIdentity,
            isGenerated: plugin.isGenerated
        )
    }
}

public extension IndexInfo {
    init(from plugin: PluginIndexInfo) {
        self.init(
            name: plugin.name,
            columns: plugin.columns,
            isUnique: plugin.isUnique,
            isPrimary: plugin.isPrimary,
            type: plugin.type
        )
    }
}

public extension ForeignKeyInfo {
    init(from plugin: PluginForeignKeyInfo) {
        self.init(
            name: plugin.name,
            column: plugin.column,
            referencedTable: plugin.referencedTable,
            referencedColumn: plugin.referencedColumn,
            referencedSchema: plugin.referencedSchema,
            onDelete: plugin.onDelete,
            onUpdate: plugin.onUpdate
        )
    }
}
