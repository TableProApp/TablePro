//
//  CassandraUserTypes.swift
//  CassandraDriverPlugin
//

import Foundation

// Foundation only, so apple/scripts/probes/check-cassandra-user-types.sh can compile it against a live server.
public enum CassandraUserTypes {
    public struct Field: Equatable, Sendable {
        public let name: String
        public let type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    // From reserved_keywords.txt in the apache-cassandra 5.0.9 jar.
    static let reservedKeywords: Set<String> = [
        "ADD", "ALLOW", "ALTER", "AND", "APPLY", "ASC", "AUTHORIZE", "BATCH", "BEGIN", "BY", "COLUMNFAMILY",
        "CREATE", "DELETE", "DESC", "DESCRIBE", "DROP", "ENTRIES", "EXECUTE", "FROM", "FULL", "GRANT", "IF",
        "IN", "INDEX", "INFINITY", "INSERT", "INTO", "IS", "KEYSPACE", "LIMIT", "MATERIALIZED", "MODIFY", "NAN",
        "NORECURSIVE", "NOT", "NULL", "OF", "ON", "OR", "ORDER", "PRIMARY", "RENAME", "REVOKE", "SCHEMA",
        "SELECT", "SET", "TABLE", "TO", "TOKEN", "TRUNCATE", "UNLOGGED", "UPDATE", "USE", "USING", "VIEW",
        "WHERE", "WITH",
    ]

    // CQL3Type.Native, the collection keywords and the parser's reserved type names, all from the 5.0.9 jar.
    // Unquoted, `text` names the native type even where a keyspace holds a type called "text".
    static let typeNames: Set<String> = [
        "ASCII", "BIGINT", "BLOB", "BOOLEAN", "COUNTER", "DATE", "DECIMAL", "DOUBLE", "DURATION", "EMPTY", "FLOAT",
        "INET", "INT", "SMALLINT", "TEXT", "TIME", "TIMESTAMP", "TIMEUUID", "TINYINT", "UUID", "VARCHAR", "VARINT",
        "FROZEN", "LIST", "MAP", "SET", "TUPLE", "VECTOR",
        "BITSTRING", "BYTE", "COMPLEX", "ENUM", "INTERVAL", "MACADDR",
    ]

    public static func listQuery(keyspace: String) -> String {
        """
        SELECT type_name, field_names, field_types FROM system_schema.types
        WHERE keyspace_name = '\(CassandraObjectQueries.escapeLiteral(keyspace))'
        """
    }

    public static func typeQuery(keyspace: String, name: String) -> String {
        listQuery(keyspace: keyspace) + " AND type_name = '\(CassandraObjectQueries.escapeLiteral(name))'"
    }

    // Nil for a field name holding ", ", which no reading of the driver's list text can place.
    public static func fields(names: String?, types: String?) -> [Field]? {
        let names = CassandraObjectQueries.names(of: names)
        let types = CassandraObjectQueries.types(of: types)
        guard !names.isEmpty, names.count == types.count else { return nil }
        return zip(names, types).map { Field(name: $0, type: $1) }
    }

    public static func definition(keyspace: String, name: String, fields: [Field]) -> String {
        let body = fields
            .map { "    \(CassandraObjectQueries.quote($0.name)) \($0.type)" }
            .joined(separator: ",\n")
        return "CREATE TYPE \(CassandraObjectQueries.quote(keyspace)).\(CassandraObjectQueries.quote(name)) (\n\(body)\n);"
    }

    public static func dropStatement(keyspace: String, name: String) -> String {
        "DROP TYPE \(CassandraObjectQueries.quote(keyspace)).\(CassandraObjectQueries.quote(name))"
    }

    // A type is usable only in its own keyspace, so the bare name is the one a column definition takes.
    public static func columnTypeSpelling(name: String, fields: [Field]?, releaseVersion: String?) -> String {
        let reference = identifier(name)
        guard let fields, holdsNonFrozenUserTypes(releaseVersion: releaseVersion),
              !fields.contains(where: { isNonFrozenCollection($0.type) })
        else { return "frozen<\(reference)>" }
        return reference
    }

    // CASSANDRA-7423 added non-frozen UDTs in 3.6. ScyllaDB reports 3.0.8 here, so it gets frozen, which it accepts.
    public static func holdsNonFrozenUserTypes(releaseVersion: String?) -> Bool {
        guard let releaseVersion else { return false }
        let parts = releaseVersion.split(separator: ".").prefix(2).map { Int($0.prefix(while: \.isNumber)) }
        guard parts.count == 2, let major = parts[0], let minor = parts[1] else { return false }
        return (major, minor) >= (3, 6)
    }

    static func isNonFrozenCollection(_ type: String) -> Bool {
        let lowered = type.trimmingCharacters(in: .whitespaces).lowercased()
        return ["list<", "set<", "map<"].contains { lowered.hasPrefix($0) }
    }

    // Cassandra's ColumnIdentifier.maybeQuote, which leaves "text" bare, plus the type names.
    public static func identifier(_ name: String) -> String {
        let isPlain = name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil
        let word = name.uppercased()
        if isPlain, !reservedKeywords.contains(word), !typeNames.contains(word) { return name }
        return CassandraObjectQueries.quote(name)
    }
}
