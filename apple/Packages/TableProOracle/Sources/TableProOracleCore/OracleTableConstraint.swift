import Foundation

// A PRIMARY KEY, UNIQUE or CHECK constraint, as `CREATE TABLE` writes it after the columns. A dump needs the keys as
// constraints, not as unique indexes: a foreign key added later fails with ORA-02270 without one on the columns it
// references.
public struct OracleTableConstraint: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case primaryKey
        case unique
        case check

        init?(code: String?) {
            switch code {
            case "P"?: self = .primaryKey
            case "U"?: self = .unique
            case "C"?: self = .check
            default: return nil
            }
        }

        var rank: Int {
            switch self {
            case .primaryKey: return 0
            case .unique: return 1
            case .check: return 2
            }
        }
    }

    public let name: String
    public let kind: Kind
    // In key order for a key. For a check, the columns its condition names.
    public let columns: [String]
    // Nil for a key.
    public var condition: String?
    // `SEARCH_CONDITION_VC` is a VARCHAR2(4000) that cuts a longer condition, so one of 4,000 bytes may be cut short.
    public let conditionMayBeCut: Bool
    public let isDeferrable: Bool
    public let isInitiallyDeferred: Bool
    public let isEnabled: Bool
    // An enabled NOVALIDATE constraint was never checked against the rows it already had, so they may break it.
    public let isValidated: Bool
    // A `SYS_C` name is numbered across the source database, so on another one it may already be taken.
    public let hasGeneratedName: Bool

    public init(
        name: String,
        kind: Kind,
        columns: [String],
        condition: String? = nil,
        conditionMayBeCut: Bool = false,
        isDeferrable: Bool = false,
        isInitiallyDeferred: Bool = false,
        isEnabled: Bool = true,
        isValidated: Bool = true,
        hasGeneratedName: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.columns = columns
        self.condition = condition
        self.conditionMayBeCut = conditionMayBeCut
        self.isDeferrable = isDeferrable
        self.isInitiallyDeferred = isInitiallyDeferred
        self.isEnabled = isEnabled
        self.isValidated = isValidated
        self.hasGeneratedName = hasGeneratedName
    }

    // Written disabled so the rows that break it still restore, then enabled after them without a check.
    public var enablesAfterRows: Bool {
        isEnabled && !isValidated
    }

    // A check with a generated name has no name to enable it by, so it is added after the rows instead of written in
    // the CREATE TABLE.
    public var isAddedAfterRows: Bool {
        enablesAfterRows && kind == .check && hasGeneratedName
    }

    // A key with a generated name is enabled by what it is, which needs no name. Nil for a check added after the rows.
    public func enableAfterRowsStatement(qualifiedTable: String, quote: (String) -> String) -> String? {
        guard enablesAfterRows else { return nil }
        guard hasGeneratedName else {
            return "ALTER TABLE \(qualifiedTable) ENABLE NOVALIDATE CONSTRAINT \(quote(name))"
        }
        switch kind {
        case .primaryKey:
            return "ALTER TABLE \(qualifiedTable) ENABLE NOVALIDATE PRIMARY KEY"
        case .unique:
            return "ALTER TABLE \(qualifiedTable) ENABLE NOVALIDATE UNIQUE (\(columns.map(quote).joined(separator: ", ")))"
        case .check:
            return nil
        }
    }

    // Oracle keeps a NOT NULL as a check reading `"COL" IS NOT NULL`, which the column's own definition already
    // writes when the column is NOT NULL.
    public func restatesNotNull(of notNullColumns: Set<String>) -> Bool {
        guard kind == .check, isEnabled, isValidated, columns.count == 1, let column = columns.first,
              notNullColumns.contains(column), let condition else { return false }
        return condition.trimmingCharacters(in: .whitespacesAndNewlines)
            == "\(OracleSchemaQueries.quoteIdentifier(column)) IS NOT NULL"
    }

    // A generated name is left for the server to choose again.
    public func clause(quote: (String) -> String) -> String {
        var parts: [String] = []
        if !hasGeneratedName {
            parts.append("CONSTRAINT \(quote(name))")
        }
        let columnList = columns.map(quote).joined(separator: ", ")
        switch kind {
        case .primaryKey:
            parts.append("PRIMARY KEY (\(columnList))")
        case .unique:
            parts.append("UNIQUE (\(columnList))")
        case .check:
            let text = (condition ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append("CHECK (\(text))")
        }
        if isDeferrable {
            parts.append(isInitiallyDeferred ? "DEFERRABLE INITIALLY DEFERRED" : "DEFERRABLE")
        }
        if !isEnabled || !isValidated {
            parts.append("DISABLE")
        }
        return parts.joined(separator: " ")
    }
}

extension OracleSchemaQueries {
    // One row per constraint column. Before 12.1 a check's text is only in a LONG oracle-nio cannot decode, so only
    // the keys are read there.
    public static func tableConstraints(schema: String, table: String, release: OracleServerRelease) -> String {
        let readsChecks = release.hasSearchConditionText
        let condition = readsChecks ? "c.SEARCH_CONDITION_VC" : "NULL"
        let conditionBytes = readsChecks ? "LENGTHB(c.SEARCH_CONDITION_VC)" : "NULL"
        let types = readsChecks ? "'P', 'U', 'C'" : "'P', 'U'"
        return """
            SELECT c.CONSTRAINT_NAME, c.CONSTRAINT_TYPE, c.DEFERRABLE, c.DEFERRED, c.STATUS, c.GENERATED,
                   \(condition) AS SEARCH_CONDITION_VC, \(conditionBytes) AS CONDITION_BYTES, cc.COLUMN_NAME,
                   c.VALIDATED
            FROM \(OracleDictionary.allConstraints) c
            LEFT JOIN \(OracleDictionary.allConsColumns) cc ON cc.OWNER = c.OWNER
                AND cc.CONSTRAINT_NAME = c.CONSTRAINT_NAME
            WHERE c.OWNER = '\(escapeLiteral(schema))'
              AND c.TABLE_NAME = '\(escapeLiteral(table))'
              AND c.CONSTRAINT_TYPE IN (\(types))
            ORDER BY c.CONSTRAINT_NAME, cc.POSITION, cc.COLUMN_NAME
            """
    }

    // Keys first, then checks, each by name, so a dump reads the same every time.
    public static func parseTableConstraints(_ rows: [[OracleRawCell]]) -> [OracleTableConstraint] {
        var order: [String] = []
        var firstRows: [String: (row: [OracleRawCell], kind: OracleTableConstraint.Kind)] = [:]
        var columns: [String: [String]] = [:]
        for row in rows {
            guard let name = row[safe: 0]?.stringValue,
                  let kind = OracleTableConstraint.Kind(code: row[safe: 1]?.stringValue) else { continue }
            if firstRows[name] == nil {
                order.append(name)
                firstRows[name] = (row, kind)
            }
            if let column = row[safe: 8]?.stringValue {
                columns[name, default: []].append(column)
            }
        }
        let constraints = order.compactMap { name -> OracleTableConstraint? in
            guard let entry = firstRows[name] else { return nil }
            let row = entry.row
            let kind = entry.kind
            let conditionBytes = row[safe: 7]?.stringValue.flatMap(OracleSchemaQueries.integer)
            return OracleTableConstraint(
                name: name,
                kind: kind,
                columns: columns[name] ?? [],
                condition: kind == .check ? row[safe: 6]?.stringValue : nil,
                conditionMayBeCut: kind == .check && (conditionBytes ?? 0) >= maxSearchConditionBytes,
                isDeferrable: row[safe: 2]?.stringValue == "DEFERRABLE",
                isInitiallyDeferred: row[safe: 3]?.stringValue == "DEFERRED",
                isEnabled: row[safe: 4]?.stringValue != "DISABLED",
                isValidated: row[safe: 9]?.stringValue != "NOT VALIDATED",
                hasGeneratedName: row[safe: 5]?.stringValue == "GENERATED NAME"
            )
        }
        return constraints.sorted { ($0.kind.rank, $0.name) < ($1.kind.rank, $1.name) }
    }

    static let maxSearchConditionBytes = 4_000
}
