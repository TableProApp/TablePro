import Foundation

nonisolated enum ColumnMetadataRules {
    static func mySQLIsAutoIncrement(extra: String?) -> Bool {
        normalized(extra).contains("AUTO_INCREMENT")
    }

    static func mySQLIsGenerated(extra: String?) -> Bool {
        let value = normalized(extra)
        return value.contains("VIRTUAL GENERATED") || value.contains("STORED GENERATED")
    }

    static func postgresIsAutoIncrement(isIdentity: String?, columnDefault: String?) -> Bool {
        if normalized(isIdentity) == "YES" { return true }
        return normalized(columnDefault).hasPrefix("NEXTVAL(")
    }

    static func postgresIsGenerated(isGenerated: String?) -> Bool {
        normalized(isGenerated) == "ALWAYS"
    }

    /// `PRAGMA table_info` reports `pk` as the column's 1-based rank inside the primary key, not as
    /// a flag, so a composite key's second column comes back as 2.
    static func sqliteIsPrimaryKey(pk: String?) -> Bool {
        guard let pk, !pk.isEmpty else { return false }
        return pk != "0"
    }

    /// Only a lone `INTEGER PRIMARY KEY` on a rowid table aliases the rowid and is filled in when
    /// omitted. The same declaration on a `WITHOUT ROWID` table is an ordinary NOT NULL column.
    static func sqliteIsRowIdAlias(
        typeName: String?,
        isPrimaryKey: Bool,
        primaryKeyCount: Int,
        createStatement: String?
    ) -> Bool {
        guard isPrimaryKey, primaryKeyCount == 1 else { return false }
        guard normalized(typeName) == "INTEGER" else { return false }
        return !normalized(createStatement).contains("WITHOUT ROWID")
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
