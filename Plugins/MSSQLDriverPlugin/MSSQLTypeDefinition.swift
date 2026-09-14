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

    public struct Index: Sendable, Equatable {
        public let name: String?
        public let isPrimaryKey: Bool
        public let isUnique: Bool
        public let typeDescription: String?
        public let keyColumns: String?

        public init(
            name: String?,
            isPrimaryKey: Bool,
            isUnique: Bool,
            typeDescription: String? = nil,
            keyColumns: String? = nil
        ) {
            self.name = name
            self.isPrimaryKey = isPrimaryKey
            self.isUnique = isUnique
            self.typeDescription = typeDescription
            self.keyColumns = keyColumns
        }
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
    /// pretending to a definition. The class name is not in `sys.assembly_types` under a name this
    /// driver reads, so the statement is left with the type's own name, which is what SQL Server
    /// requires them to match in practice.
    public static func clrStatement(schema: String, name: String, assembly: String?) -> String {
        let external = assembly.map { "\(bracketed($0)).[\(name)]" } ?? "<assembly>.[\(name)]"
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
        databaseCollation: String?
    ) -> String {
        let singleColumnPrimaryKey = indexes.first { $0.isPrimaryKey && !($0.keyColumns?.contains(",") ?? true) }?.keyColumns
        var lines = columns.map { column in
            columnClause(column, primaryKeyColumn: singleColumnPrimaryKey, databaseCollation: databaseCollation)
        }
        lines.append(contentsOf: indexClauses(indexes, inlinedPrimaryKey: singleColumnPrimaryKey))
        let body = lines.map { "    \($0)" }.joined(separator: ",\n")
        return "CREATE TYPE \(bracketed(schema)).\(bracketed(name)) AS TABLE (\n\(body)\n);"
    }

    private static func columnClause(_ column: Column, primaryKeyColumn: String?, databaseCollation: String?) -> String {
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
        if let key = primaryKeyColumn, key == column.name { parts.append("PRIMARY KEY") }
        return parts.joined(separator: " ")
    }

    private static func indexClauses(_ indexes: [Index], inlinedPrimaryKey: String?) -> [String] {
        indexes.compactMap { index -> String? in
            guard let keyColumns = index.keyColumns, !keyColumns.isEmpty else { return nil }
            let columnList = keyColumns
                .split(separator: ",")
                .map { bracketed($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
            if index.isPrimaryKey {
                guard inlinedPrimaryKey != keyColumns else { return nil }
                return "PRIMARY KEY (\(columnList))"
            }
            guard let name = index.name, !name.isEmpty else {
                return index.isUnique ? "UNIQUE (\(columnList))" : nil
            }
            let clustering = index.typeDescription.map { " \($0.replacingOccurrences(of: "_", with: " "))" } ?? ""
            let unique = index.isUnique ? "UNIQUE " : ""
            return "\(unique)INDEX \(bracketed(name))\(clustering) (\(columnList))"
        }
    }
}
