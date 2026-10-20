//
//  PgvectorTypes.swift
//  PostgreSQLDriverPlugin
//

import Foundation

enum PgvectorTypes {
    static let typeNames: Set<String> = ["vector", "halfvec", "sparsevec"]

    // A base type, so a user's composite or domain that happens to be named `vector` is not taken for one.
    static let probeQuery = """
        SELECT t.oid::text, t.typarray::text, t.typname
        FROM pg_catalog.pg_type t
        WHERE t.typtype = 'b' AND t.typname IN ('vector', 'halfvec', 'sparsevec')
        """

    static func names(fromProbeRows rows: [[String?]]) -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        for row in rows {
            guard row.count >= 3,
                  let oid = row[0].flatMap({ UInt32($0) }),
                  let name = row[2], typeNames.contains(name) else { continue }
            names[oid] = name
            if let arrayOid = row[1].flatMap({ UInt32($0) }), arrayOid != 0 {
                names[arrayOid] = "\(name)[]"
            }
        }
        return names
    }

    // pgvector stores the dimension count as the type modifier; -1 is a column declared without one.
    static func spelling(of typeName: String, modifier: Int32) -> String {
        guard modifier > 0 else { return typeName }
        let isArray = typeName.hasSuffix("[]")
        let base = isArray ? String(typeName.dropLast(2)) : typeName
        guard typeNames.contains(base) else { return typeName }
        return "\(base)(\(modifier))" + (isArray ? "[]" : "")
    }
}
