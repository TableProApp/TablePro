//
//  MSSQLTypeDefinition.swift
//  MSSQLDriverPlugin
//
//  Rebuilds a CREATE TYPE statement from the catalog. Pure, so it is testable without a server.
//

import Foundation
import TableProPluginKit

/// A type has no `sys.sql_modules` row on any engine path, so unlike a procedure there is no stored
/// text to read back. Every statement here is synthesized from the catalog, and both shapes were
/// executed against SQL Server 2022 to prove they parse.
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

    /// Keys stay structured rather than comma-joined: a column name may legally contain a comma,
    /// and only a per-key flag can carry `DESC`.
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
        "[\(identifier.replacingOccurrences(of: "]", with: "]]"))]"
    }

    /// `CREATE TYPE x FROM base NULL|NOT NULL`. Nullability is always spelled out, because the
    /// default differs with `ANSI_NULL_DFLT_ON` and a reader cannot tell which applied.
    public static func aliasStatement(schema: String, name: String, baseType: String?, isNullable: Bool) -> String {
        let base = baseType.map { " FROM \($0)" } ?? ""
        return "CREATE TYPE \(bracketed(schema)).\(bracketed(name))\(base) \(isNullable ? "NULL" : "NOT NULL");"
    }

    /// A CLR type's body is compiled into a .NET assembly, so this names the assembly rather than
    /// pretending to a definition. The managed class is `sys.assembly_types.assembly_class` and is
    /// free to differ from the SQL type's name; substituting the SQL name produced an
    /// `EXTERNAL NAME` pointing at a class that does not exist.
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

    /// `CREATE TYPE x AS TABLE (...)`. A primary key goes inline on its column when it covers one
    /// column, because that is how it reads back and because the constraint's own name is
    /// server-generated (`PK__TT_IdLis__3214EC07...`) and carrying it forward is noise.
    public static func tableStatement(
        schema: String,
        name: String,
        columns: [Column],
        indexes: [Index],
        checkConstraints: [String] = [],
        isMemoryOptimized: Bool = false,
        databaseCollation: String?
    ) -> String {
        let primaryKey = indexes.first(where: \.isPrimaryKey)
        let inlinedKey = primaryKey.flatMap { key -> IndexKey? in
            guard key.keys.count == 1, let only = key.keys.first, !only.isDescending else { return nil }
            return only
        }
        var lines = columns.map { column in
            columnClause(
                column,
                primaryKey: inlinedKey.map { ($0.column, primaryKey?.typeDescription) },
                databaseCollation: databaseCollation
            )
        }
        lines.append(contentsOf: indexClauses(indexes, inlinedPrimaryKeyColumn: inlinedKey?.column))
        lines.append(contentsOf: checkConstraints.filter { !$0.isEmpty }.map { "CHECK \($0)" })
        let body = lines.map { "    \($0)" }.joined(separator: ",\n")
        let tail = isMemoryOptimized ? "\n)\nWITH (MEMORY_OPTIMIZED = ON);" : "\n);"
        return "CREATE TYPE \(bracketed(schema)).\(bracketed(name)) AS TABLE (\n\(body)\(tail)"
    }

    /// SQL Server defaults a primary key to CLUSTERED, so a NONCLUSTERED one replays with a
    /// different layout, and a clustered secondary index then makes the replay fail outright.
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
    ) -> String {
        var parts = [bracketed(column.name)]
        if let computed = column.computedDefinition, !computed.isEmpty {
            parts.append("AS \(computed)")
            return parts.joined(separator: " ")
        }
        if let type = column.type, !type.isEmpty { parts.append(type) }
        if let collation = column.collation, !collation.isEmpty, collation != databaseCollation {
            parts.append("COLLATE \(collation)")
        }
        if let identity = column.identitySpec, !identity.isEmpty { parts.append("IDENTITY(\(identity))") }
        parts.append(column.isNullable ? "NULL" : "NOT NULL")
        if let value = column.defaultDefinition, !value.isEmpty { parts.append("DEFAULT \(value)") }
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
