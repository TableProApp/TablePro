import Foundation
import TableProPluginKit

enum PostgreSQLCatalogForeignKeys {
    static let constraintParentMinimumServerVersion: Int32 = 110_000

    enum Column: Int, CaseIterable {
        case constraintIdentity
        case constraintName
        case referencedSchema
        case referencedTable
        case deleteAction
        case updateAction
        case sourceKeys
        case referencedKeys
        case side
        case attributeNumber
        case attributeName
    }

    enum Side: String, CaseIterable {
        case source = "s"
        case referenced = "r"

        fileprivate var relationColumn: String {
            switch self {
            case .source: return "c.conrelid"
            case .referenced: return "c.confrelid"
            }
        }

        fileprivate var keyColumn: String {
            switch self {
            case .source: return "c.conkey"
            case .referenced: return "c.confkey"
            }
        }
    }

    static func query(schemaLiteral: String, tableLiteral: String, excludesPartitionClones: Bool) -> String {
        let cloneFilter = excludesPartitionClones ? """

              AND NOT EXISTS (
                    SELECT 1
                    FROM pg_catalog.pg_constraint parent
                    WHERE parent.oid = c.conparentid
                      AND parent.conrelid = c.conrelid)
            """ : ""
        let branches = Side.allCases.map { side in
            """
            SELECT c.oid, c.conname, ref_ns.nspname, ref_cl.relname, c.confdeltype, c.confupdtype,
                   c.conkey, c.confkey, '\(side.rawValue)', a.attnum, a.attname
            FROM pg_catalog.pg_constraint c
            JOIN pg_catalog.pg_class cl ON cl.oid = c.conrelid
            JOIN pg_catalog.pg_namespace ns ON ns.oid = cl.relnamespace
            JOIN pg_catalog.pg_class ref_cl ON ref_cl.oid = c.confrelid
            JOIN pg_catalog.pg_namespace ref_ns ON ref_ns.oid = ref_cl.relnamespace
            JOIN pg_catalog.pg_attribute a ON a.attrelid = \(side.relationColumn) AND a.attnum = ANY (\(side.keyColumn))
            WHERE c.contype = 'f'
              AND ns.nspname = \(schemaLiteral)
              AND cl.relname = \(tableLiteral)\(cloneFilter)
            """
        }
        return branches.joined(separator: "\nUNION ALL\n") + "\nORDER BY 2, 1"
    }

    static func excludesPartitionClones(serverVersionNumber: Int32) -> Bool {
        serverVersionNumber >= constraintParentMinimumServerVersion
    }

    static func foreignKeys(from rows: [[String?]]) -> [PluginForeignKeyInfo] {
        var identities: [String] = []
        var constraints: [String: CatalogForeignKey] = [:]
        for row in rows {
            guard let keyRow = CatalogKeyRow(row) else { continue }
            if constraints[keyRow.constraintIdentity] == nil {
                identities.append(keyRow.constraintIdentity)
                constraints[keyRow.constraintIdentity] = CatalogForeignKey(keyRow)
            }
            constraints[keyRow.constraintIdentity]?.record(keyRow)
        }
        return identities.flatMap { constraints[$0]?.pairs ?? [] }
    }

    static func referentialAction(_ code: String?) -> String {
        switch code {
        case "r": return "RESTRICT"
        case "c": return "CASCADE"
        case "n": return "SET NULL"
        case "d": return "SET DEFAULT"
        default: return "NO ACTION"
        }
    }
}

private struct CatalogKeyRow {
    let constraintIdentity: String
    let constraintName: String
    let referencedSchema: String?
    let referencedTable: String
    let deleteAction: String?
    let updateAction: String?
    let sourceKeys: [Int]
    let referencedKeys: [Int]
    let side: PostgreSQLCatalogForeignKeys.Side
    let attributeNumber: Int
    let attributeName: String

    init?(_ row: [String?]) {
        typealias Column = PostgreSQLCatalogForeignKeys.Column
        guard row.count >= Column.allCases.count,
              let identity = row[Column.constraintIdentity.rawValue],
              let name = row[Column.constraintName.rawValue],
              let referencedTable = row[Column.referencedTable.rawValue],
              let sourceKeys = Self.attributeNumbers(row[Column.sourceKeys.rawValue]),
              let referencedKeys = Self.attributeNumbers(row[Column.referencedKeys.rawValue]),
              let sideCode = row[Column.side.rawValue],
              let side = PostgreSQLCatalogForeignKeys.Side(rawValue: sideCode),
              let attributeNumberText = row[Column.attributeNumber.rawValue],
              let attributeNumber = Int(attributeNumberText),
              let attributeName = row[Column.attributeName.rawValue]
        else { return nil }
        self.constraintIdentity = identity
        self.constraintName = name
        self.referencedSchema = row[Column.referencedSchema.rawValue]
        self.referencedTable = referencedTable
        self.deleteAction = row[Column.deleteAction.rawValue]
        self.updateAction = row[Column.updateAction.rawValue]
        self.sourceKeys = sourceKeys
        self.referencedKeys = referencedKeys
        self.side = side
        self.attributeNumber = attributeNumber
        self.attributeName = attributeName
    }

    private static func attributeNumbers(_ text: String?) -> [Int]? {
        guard let text, let elements = PostgresArrayLiteralCodec.parse(text) else { return nil }
        var numbers: [Int] = []
        for element in elements {
            guard case .value(let value) = element, let number = Int(value) else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}

private struct CatalogForeignKey {
    let name: String
    let referencedSchema: String?
    let referencedTable: String
    let onDelete: String
    let onUpdate: String
    let sourceKeys: [Int]
    let referencedKeys: [Int]
    var sourceNames: [Int: String] = [:]
    var referencedNames: [Int: String] = [:]

    init(_ row: CatalogKeyRow) {
        self.name = row.constraintName
        self.referencedSchema = row.referencedSchema
        self.referencedTable = row.referencedTable
        self.onDelete = PostgreSQLCatalogForeignKeys.referentialAction(row.deleteAction)
        self.onUpdate = PostgreSQLCatalogForeignKeys.referentialAction(row.updateAction)
        self.sourceKeys = row.sourceKeys
        self.referencedKeys = row.referencedKeys
    }

    mutating func record(_ row: CatalogKeyRow) {
        switch row.side {
        case .source: sourceNames[row.attributeNumber] = row.attributeName
        case .referenced: referencedNames[row.attributeNumber] = row.attributeName
        }
    }

    var pairs: [PluginForeignKeyInfo] {
        guard sourceKeys.count == referencedKeys.count else { return [] }
        return zip(sourceKeys, referencedKeys).compactMap { sourceKey, referencedKey in
            guard let column = sourceNames[sourceKey], let referencedColumn = referencedNames[referencedKey] else {
                return nil
            }
            return PluginForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: referencedTable,
                referencedColumn: referencedColumn,
                referencedSchema: referencedSchema,
                onDelete: onDelete,
                onUpdate: onUpdate
            )
        }
    }
}
