//
//  PostgreSQLCatalogTypeNames.swift
//  PostgreSQLDriver
//

import Foundation

/// The spelling a result column gets when its type oid is not in libpq's built-in table: an
/// enum is `ENUM(name)` and an enum array `ENUM[](name)`, which is what the column classifier
/// reads, a domain is its base type so the cell edits as one, and anything else is its own name.
/// Both the connect-time enum probe and the per-result lookup spell through here, so a column
/// reads the same whether its type existed at connect or was created a moment ago.
enum PostgreSQLCatalogTypeNames {
    static let unresolved = "unknown"

    static func enumTypeName(_ name: String) -> String { "ENUM(\(name))" }

    static func enumArrayTypeName(_ name: String) -> String { "ENUM[](\(name))" }

    struct Row: Equatable {
        let oid: UInt32
        let name: String
        let kind: Character
        let domainBase: String?
        let elementName: String?
        let elementKind: Character?
        let elementDomainBase: String?
    }

    /// An array is `typelem` set on a variable-length type rather than `typcategory = 'A'`,
    /// because Redshift's catalog predates `typcategory` and the predicate agrees with it on
    /// every real type: `point` and `name` carry a `typelem` at a fixed length, and the one
    /// disagreement is the pseudo-type `_record`, which no column has.
    static func lookupQuery(oids: [UInt32]) -> String? {
        let list = Set(oids).sorted().map(String.init).joined(separator: ", ")
        guard !list.isEmpty else { return nil }
        return """
            SELECT t.oid::text, t.typname, t.typtype::text,
                   CASE WHEN t.typtype = 'd' THEN pg_catalog.format_type(t.typbasetype, t.typtypmod) END,
                   el.typname, el.typtype::text,
                   CASE WHEN el.typtype = 'd' THEN pg_catalog.format_type(el.typbasetype, el.typtypmod) END
            FROM pg_catalog.pg_type t
            LEFT JOIN pg_catalog.pg_type el ON el.oid = t.typelem AND t.typlen = -1
            WHERE t.oid IN (\(list))
            """
    }

    static func row(fromColumns columns: [String?]) -> Row? {
        guard columns.count >= 7,
              let oid = columns[0].flatMap({ UInt32($0) }),
              let name = columns[1],
              let kind = columns[2]?.first else { return nil }
        return Row(
            oid: oid,
            name: name,
            kind: kind,
            domainBase: columns[3],
            elementName: columns[4],
            elementKind: columns[5]?.first,
            elementDomainBase: columns[6]
        )
    }

    static func typeName(for row: Row) -> String {
        if let elementName = row.elementName {
            guard row.elementKind != "e" else { return enumArrayTypeName(elementName) }
            return "\(row.elementDomainBase ?? elementName)[]"
        }
        if row.kind == "e" { return enumTypeName(row.name) }
        if row.kind == "d", let base = row.domainBase { return base }
        return row.name
    }

    /// The connect-time probe and the refresh after a `CREATE TYPE` both read every enum with its
    /// scalar and array oids; a zero array oid is a server that does not give enums one.
    static func enumProbeNames(rows: [[String?]]) -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        for row in rows {
            guard row.count >= 3,
                  let scalarOid = row[0].flatMap({ UInt32($0) }),
                  let typeName = row[2] else { continue }
            names[scalarOid] = enumTypeName(typeName)
            if let arrayOid = row[1].flatMap({ UInt32($0) }), arrayOid != 0 {
                names[arrayOid] = enumArrayTypeName(typeName)
            }
        }
        return names
    }

    /// Every oid asked about gets an entry, so an oid the catalog does not know is not asked
    /// about again on every following result.
    static func names(for oids: [UInt32], rows: [[String?]]) -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        for oid in oids {
            names[oid] = unresolved
        }
        for row in rows.compactMap(row(fromColumns:)) {
            names[row.oid] = typeName(for: row)
        }
        return names
    }
}
