import Foundation
import TableProSQLQuoting

// A type has no `sys.sql_modules` row, so every statement here is rebuilt from the catalog.
public enum MSSQLTypeDefinition {
    public struct Column: Sendable, Equatable {
        public let name: String
        public let type: String?
        public let isNullable: Bool
        public let identitySpec: String?
        public let computedDefinition: String?
        public let defaultDefinition: String?
        public let collation: String?

        public init(
            name: String,
            type: String?,
            isNullable: Bool,
            identitySpec: String? = nil,
            computedDefinition: String? = nil,
            defaultDefinition: String? = nil,
            collation: String? = nil
        ) {
            self.name = name
            self.type = type
            self.isNullable = isNullable
            self.identitySpec = identitySpec
            self.computedDefinition = computedDefinition
            self.defaultDefinition = defaultDefinition
            self.collation = collation
        }
    }

    public struct IndexKey: Sendable, Equatable {
        public let column: String
        public let isDescending: Bool

        public init(column: String, isDescending: Bool) {
            self.column = column
            self.isDescending = isDescending
        }
    }

    public struct Index: Sendable, Equatable {
        public let name: String?
        public let isPrimaryKey: Bool
        public let isUnique: Bool
        public let typeDescription: String?
        public let keys: [IndexKey]
        public let bucketCount: Int

        public init(
            name: String?,
            isPrimaryKey: Bool,
            isUnique: Bool,
            typeDescription: String? = nil,
            keys: [IndexKey] = [],
            bucketCount: Int = 0
        ) {
            self.name = name
            self.isPrimaryKey = isPrimaryKey
            self.isUnique = isUnique
            self.typeDescription = typeDescription
            self.keys = keys
            self.bucketCount = bucketCount
        }

        var columnNames: [String] { keys.map(\.column) }
    }

    public static func bracketed(_ identifier: String) -> String {
        SQLQuoting.identifier(identifier, quote: .bracket)
    }

    // Rows are what `MSSQLTypeQueries.tableTypeColumns` selects.
    public static func columns(fromRows rows: [[String?]]) -> [Column] {
        rows.compactMap { row -> Column? in
            guard let name = cell(row, 0) else { return nil }
            return Column(
                name: name,
                type: cell(row, 1),
                isNullable: cell(row, 2) == "1",
                identitySpec: cell(row, 3),
                computedDefinition: cell(row, 4),
                defaultDefinition: cell(row, 5),
                collation: cell(row, 6)
            )
        }
    }

    // Rows are what `MSSQLTypeQueries.tableTypeIndexes` selects, one per key column, folded by `index_id`.
    public static func indexes(fromRows rows: [[String?]]) -> [Index] {
        var order: [String] = []
        var byId: [String: Index] = [:]
        for row in rows {
            guard let indexId = cell(row, 6), let column = cell(row, 4) else { continue }
            let key = IndexKey(column: column, isDescending: cell(row, 5) == "1")
            if let existing = byId[indexId] {
                byId[indexId] = Index(
                    name: existing.name,
                    isPrimaryKey: existing.isPrimaryKey,
                    isUnique: existing.isUnique,
                    typeDescription: existing.typeDescription,
                    keys: existing.keys + [key],
                    bucketCount: existing.bucketCount
                )
                continue
            }
            order.append(indexId)
            byId[indexId] = Index(
                name: cell(row, 0),
                isPrimaryKey: cell(row, 1) == "1",
                isUnique: cell(row, 2) == "1",
                typeDescription: cell(row, 3),
                keys: [key],
                bucketCount: cell(row, 7).flatMap(Int.init) ?? 0
            )
        }
        return order.compactMap { byId[$0] }
    }

    // Rows are what `MSSQLTypeQueries.tableTypeCheckConstraints` selects.
    public static func checkConstraints(fromRows rows: [[String?]]) -> [String] {
        rows.compactMap { cell($0, 0) }
    }

    private static func cell(_ row: [String?], _ index: Int) -> String? {
        row.indices.contains(index) ? row[index] : nil
    }

    // Nullability is always spelled out: the default differs with `ANSI_NULL_DFLT_ON`.
    public static func aliasStatement(schema: String, name: String, baseType: String?, isNullable: Bool) throws -> String {
        if let baseType, !MSSQLDefinitionText.isColumnType(baseType) {
            throw MSSQLDefinitionRefusal.columnType(name, baseType)
        }
        let base = baseType.map { " FROM \($0)" } ?? ""
        return "CREATE TYPE \(bracketed(schema)).\(bracketed(name))\(base) \(isNullable ? "NULL" : "NOT NULL");"
    }

    // The managed class may differ from the SQL type's name, so it comes from `sys.assembly_types`.
    public static func clrStatement(
        schema: String,
        name: String,
        assembly: String?,
        assemblyClass: String?
    ) -> String {
        let managedClass = (assemblyClass?.isEmpty == false ? assemblyClass : nil) ?? name
        let external = assembly.map { "\(bracketed($0)).\(bracketed(managedClass))" }
            ?? "<assembly>.\(bracketed(managedClass))"
        return "CREATE TYPE \(bracketed(schema)).\(bracketed(name)) EXTERNAL NAME \(external);"
    }

    // A single-column primary key goes inline: its constraint name is server-generated (`PK__TT_IdLis__3214EC07...`).
    public static func tableStatement(
        schema: String,
        name: String,
        columns: [Column],
        indexes: [Index],
        checkConstraints: [String] = [],
        isMemoryOptimized: Bool = false,
        databaseCollation: String?
    ) throws -> String {
        let primaryKey = indexes.first(where: \.isPrimaryKey)
        let inlinedKey = primaryKey.flatMap { key -> IndexKey? in
            guard key.keys.count == 1, let only = key.keys.first, !only.isDescending else { return nil }
            return only
        }
        var lines = try columns.map { column in
            try columnClause(
                column,
                primaryKey: inlinedKey.map { ($0.column, primaryKey?.typeDescription) },
                databaseCollation: databaseCollation
            )
        }
        let checks = try checkConstraints.filter { !$0.isEmpty }.map { check -> String in
            guard let expression = MSSQLDefinitionText.expression(check) else {
                throw MSSQLDefinitionRefusal.checkConstraint(name)
            }
            return "CHECK \(expression)"
        }
        lines.append(contentsOf: indexClauses(indexes, inlinedPrimaryKeyColumn: inlinedKey?.column))
        lines.append(contentsOf: checks)
        let body = lines.map { "    \($0)" }.joined(separator: ",\n")
        let tail = isMemoryOptimized ? "\n)\nWITH (MEMORY_OPTIMIZED = ON);" : "\n);"
        return "CREATE TYPE \(bracketed(schema)).\(bracketed(name)) AS TABLE (\n\(body)\(tail)"
    }

    // A primary key defaults to CLUSTERED, so a NONCLUSTERED one has to say so.
    private static func clusteringClause(_ typeDescription: String?) -> String {
        guard let description = typeDescription?.uppercased(),
              description == "CLUSTERED" || description == "NONCLUSTERED"
        else {
            return ""
        }
        return " \(description)"
    }

    private static func columnClause(
        _ column: Column,
        primaryKey: (column: String, clustering: String?)?,
        databaseCollation: String?
    ) throws -> String {
        var parts = [bracketed(column.name)]
        if let computed = column.computedDefinition, !computed.isEmpty {
            guard let expression = MSSQLDefinitionText.expression(computed) else {
                throw MSSQLDefinitionRefusal.computedColumn(column.name)
            }
            parts.append("AS \(expression)")
            return parts.joined(separator: " ")
        }
        if let type = column.type, !type.isEmpty {
            guard MSSQLDefinitionText.isColumnType(type) else { throw MSSQLDefinitionRefusal.columnType(column.name, type) }
            parts.append(type)
        }
        if let collation = column.collation, !collation.isEmpty, collation != databaseCollation {
            guard MSSQLDefinitionText.isCollationName(collation) else {
                throw MSSQLDefinitionRefusal.collation(column.name, collation)
            }
            parts.append("COLLATE \(collation)")
        }
        if let identity = column.identitySpec, !identity.isEmpty {
            guard MSSQLDefinitionText.isIdentitySpecification(identity) else {
                throw MSSQLDefinitionRefusal.identity(column.name, identity)
            }
            parts.append("IDENTITY(\(identity))")
        }
        parts.append(column.isNullable ? "NULL" : "NOT NULL")
        if let value = column.defaultDefinition, !value.isEmpty {
            guard let expression = MSSQLDefinitionText.expression(value) else {
                throw MSSQLDefinitionRefusal.columnDefault(column.name)
            }
            parts.append("DEFAULT \(expression)")
        }
        if let primaryKey, primaryKey.column == column.name {
            parts.append("PRIMARY KEY\(clusteringClause(primaryKey.clustering))")
        }
        return parts.joined(separator: " ")
    }

    private static func keyList(_ keys: [IndexKey]) -> String {
        keys
            .map { "\(bracketed($0.column))\($0.isDescending ? " DESC" : "")" }
            .joined(separator: ", ")
    }

    private static func indexClauses(_ indexes: [Index], inlinedPrimaryKeyColumn: String?) -> [String] {
        indexes.compactMap { index -> String? in
            guard !index.keys.isEmpty else { return nil }
            let columnList = keyList(index.keys)
            if index.isPrimaryKey {
                guard index.columnNames != [inlinedPrimaryKeyColumn].compactMap({ $0 }) else { return nil }
                return "PRIMARY KEY\(clusteringClause(index.typeDescription)) (\(columnList))"
            }
            guard let name = index.name, !name.isEmpty else {
                return index.isUnique ? "UNIQUE (\(columnList))" : nil
            }
            let unique = index.isUnique ? "UNIQUE " : ""
            if index.bucketCount > 0 {
                return "\(unique)INDEX \(bracketed(name)) HASH (\(columnList)) WITH (BUCKET_COUNT = \(index.bucketCount))"
            }
            return "\(unique)INDEX \(bracketed(name))\(clusteringClause(index.typeDescription)) (\(columnList))"
        }
    }
}
