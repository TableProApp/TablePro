//
//  MySQLGeneratedColumnClassification.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// MySQL and MariaDB report generated columns through the `Extra` column of
/// `SHOW FULL COLUMNS` and `INFORMATION_SCHEMA.COLUMNS.EXTRA`.
///
/// MySQL, and MariaDB from 10.2, report "STORED GENERATED" or "VIRTUAL
/// GENERATED" and may append further attributes: MySQL separates them with a
/// space ("STORED GENERATED INVISIBLE"), MariaDB with a comma ("STORED
/// GENERATED, INVISIBLE"), so the marker is matched as a substring. MariaDB
/// 10.1 and older instead report the whole value as bare "VIRTUAL" or
/// "PERSISTENT", and never combine it with another attribute.
///
/// "DEFAULT_GENERATED" is a MySQL 8 expression default, not a generated column,
/// and stays insertable.
internal func mysqlColumnIsGenerated(extra: String?) -> Bool {
    guard let extra else { return false }
    let upper = extra.uppercased()
    if upper.contains("STORED GENERATED") || upper.contains("VIRTUAL GENERATED") {
        return true
    }
    let trimmed = upper.trimmingCharacters(in: .whitespaces)
    return trimmed == "VIRTUAL" || trimmed == "PERSISTENT"
}

/// The kind, from the same `Extra` value. MariaDB 10.1 and older spell stored as "PERSISTENT".
internal func mysqlGenerationKind(extra: String?) -> GenerationKind? {
    guard let extra, mysqlColumnIsGenerated(extra: extra) else { return nil }
    let upper = extra.uppercased()
    if upper.contains("STORED GENERATED") || upper.trimmingCharacters(in: .whitespaces) == "PERSISTENT" {
        return .stored
    }
    return .virtual
}
