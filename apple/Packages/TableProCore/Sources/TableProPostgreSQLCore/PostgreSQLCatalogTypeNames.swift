import Foundation

/// The spelling a result column gets for its type oid. A built-in type's oid is fixed in PostgreSQL's
/// own catalog, so `builtinTypeName(for:)` spells it from a table kept here. Any other type is read
/// from the catalog: an enum is `ENUM(name)` and an enum array `ENUM[](name)`, which is what the
/// column classifier reads, a domain is its base type so the cell edits as one, and anything else is
/// its own name. Both the connect-time enum probe and the per-result lookup spell through here, so a
/// column reads the same whether its type existed at connect or was created a moment ago.
public enum PostgreSQLCatalogTypeNames {
    public static let unresolved = "unknown"

    public static func builtinTypeName(for oid: UInt32) -> String? {
        switch oid {
        case 16: return "boolean"
        case 17: return "bytea"
        case 18: return "char"
        case 19: return "name"
        case 20: return "bigint"
        case 21: return "smallint"
        case 23: return "integer"
        case 25: return "text"
        case 26: return "oid"
        case 114: return "json"
        case 142: return "xml"
        case 600: return "point"
        case 601: return "lseg"
        case 602: return "path"
        case 603: return "box"
        case 604: return "polygon"
        case 628: return "line"
        case 650: return "cidr"
        case 700: return "real"
        case 701: return "double precision"
        case 718: return "circle"
        case 829: return "macaddr"
        case 869: return "inet"
        case 1_009: return "text[]"
        case 1_000: return "boolean[]"
        case 1_001: return "bytea[]"
        case 1_005: return "smallint[]"
        case 1_007: return "integer[]"
        case 1_014: return "char[]"
        case 1_015: return "varchar[]"
        case 1_016: return "bigint[]"
        case 1_021: return "real[]"
        case 1_022: return "double precision[]"
        case 1_115: return "timestamp[]"
        case 1_182: return "date[]"
        case 1_183: return "time[]"
        case 1_185: return "timestamptz[]"
        case 1_187: return "interval[]"
        case 1_231: return "numeric[]"
        case 1_270: return "timetz[]"
        case 199: return "json[]"
        case 3_807: return "jsonb[]"
        case 2_951: return "uuid[]"
        case 1_041: return "inet[]"
        case 1_042: return "char"
        case 1_043: return "varchar"
        case 1_082: return "date"
        case 1_083: return "time"
        case 1_114: return "timestamp"
        case 1_184: return "timestamptz"
        case 1_266: return "timetz"
        case 1_700: return "numeric"
        case 2_950: return "uuid"
        case 3_802: return "jsonb"
        default: return nil
        }
    }

    public static func enumTypeName(_ name: String) -> String { "ENUM(\(name))" }

    public static func enumArrayTypeName(_ name: String) -> String { "ENUM[](\(name))" }

    public struct Row: Equatable {
        public let oid: UInt32
        public let name: String
        public let kind: Character
        public let domainBase: String?
        public let elementName: String?
        public let elementKind: Character?
        public let elementDomainBase: String?

        public init(
            oid: UInt32,
            name: String,
            kind: Character,
            domainBase: String?,
            elementName: String?,
            elementKind: Character?,
            elementDomainBase: String?
        ) {
            self.oid = oid
            self.name = name
            self.kind = kind
            self.domainBase = domainBase
            self.elementName = elementName
            self.elementKind = elementKind
            self.elementDomainBase = elementDomainBase
        }
    }

    /// An array is `typelem` set on a variable-length type rather than `typcategory = 'A'`,
    /// because Redshift's catalog predates `typcategory` and the predicate agrees with it on
    /// every real type: `point` and `name` carry a `typelem` at a fixed length, and the one
    /// disagreement is the pseudo-type `_record`, which no column has.
    ///
    /// Sent on the user's own session under its search path, so each oid is typed: a bare integer compares oid with
    /// integer, which a `=(oid, integer)` in a schema on that path takes exactly.
    public static func lookupQuery(oids: [UInt32]) -> String? {
        let list = Set(oids).sorted().map { "'\($0)'::pg_catalog.oid" }.joined(separator: ", ")
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

    public static func row(fromColumns columns: [String?]) -> Row? {
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

    public static func typeName(for row: Row) -> String {
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
    public static func enumProbeNames(rows: [[String?]]) -> [UInt32: String] {
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
    public static func names(for oids: [UInt32], rows: [[String?]]) -> [UInt32: String] {
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
