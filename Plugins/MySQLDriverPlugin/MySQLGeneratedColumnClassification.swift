//
//  MySQLGeneratedColumnClassification.swift
//  MySQLDriverPlugin
//

import Foundation

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
