//
//  MySQLGeneratedColumnClassification.swift
//  MySQLDriverPlugin
//

/// MySQL reports generated columns via the `Extra` column of `SHOW FULL COLUMNS`
/// (and `INFORMATION_SCHEMA.COLUMNS.EXTRA`) as "STORED GENERATED" or "VIRTUAL GENERATED".
/// Plain "DEFAULT_GENERATED" (expression defaults, MySQL 8+) is not a generated column
/// and must not match.
internal func mysqlColumnIsGenerated(extra: String?) -> Bool {
    guard let extra else { return false }
    let upper = extra.uppercased()
    return upper.contains("STORED GENERATED") || upper.contains("VIRTUAL GENERATED")
}
