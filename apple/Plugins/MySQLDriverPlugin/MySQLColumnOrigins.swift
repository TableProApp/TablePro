//
//  MySQLColumnOrigins.swift
//  MySQLDriverPlugin
//

import CMariaDB
import Foundation
import TableProPluginKit

// The server names the table and column a result column reads, but a column read through a derived table, a CTE,
// JSON_TABLE or a procedure comes back under the alias it was given there, which the statement chooses. Measured on
// MySQL 8.4.13 and MariaDB 13.0.2. So origins are kept only for a statement that has one SELECT and none of those,
// and the server reports none for an expression or a set operation.
nonisolated internal enum MySQLColumnOrigins {
    // Only the two servers measured; another flavor's field names are not vouched for.
    static func origins(
        of fields: UnsafeMutablePointer<MYSQL_FIELD>?,
        count: Int,
        encoding: MySQLConnectionEncoding,
        flavor: MySQLServerFlavor,
        statement: String
    ) -> [PluginColumnOrigin?]? {
        guard flavor == .mysql || flavor == .mariadb, let fields else { return nil }
        // Every column untrusted, not "no origins": nil would let a browse prove by name, and a filter value can hold the word.
        guard readsTableColumnsDirectly(statement) else { return Array(repeating: nil, count: count) }
        return (0..<count).map { origin(of: fields[$0], encoding: encoding) }
    }

    // JSON_TABLE reports `*any*` on MariaDB and an empty schema on MySQL, a recursive CTE an empty one on both.
    static func origin(of field: MYSQL_FIELD, encoding: MySQLConnectionEncoding) -> PluginColumnOrigin? {
        guard let schema = text(field.db, length: field.db_length, encoding: encoding), schema != "*any*",
              !systemSchemas.contains(schema.lowercased()),
              let table = text(field.org_table, length: field.org_table_length, encoding: encoding),
              let column = text(field.org_name, length: field.org_name_length, encoding: encoding)
        else { return nil }
        return PluginColumnOrigin(schema: schema, table: table, column: column)
    }

    // Only a user table is vouched for. These repeat other tables' values: `data_locks.LOCK_DATA` and
    // `INNODB_LOCKS.lock_data` an indexed key, `events_statements_history.MESSAGE_TEXT` an error's text,
    // `user_variables_by_thread` what was read into a variable, and the histograms and the optimizer trace samples.
    private static let systemSchemas = Set(MySQLSystemDatabases.mysql.map { $0.lowercased() })

    private static func text(
        _ pointer: UnsafeMutablePointer<CChar>?,
        length: UInt32,
        encoding: MySQLConnectionEncoding
    ) -> String? {
        guard let pointer, length > 0 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: strnlen(pointer, Int(length)))
        let decoded = mysqlSessionText(bytes, encoding: encoding)
        return decoded.isEmpty ? nil : decoded
    }

    // A set operation needs a second SELECT, TABLE or VALUES, and a derived table one of those or WITH, so a second
    // SELECT or any of these words ends the trust. A word inside a literal or a comment counts too: it masks that one
    // result whole.
    private static let executableCommentOpeners = ["/*!", "/*M!"]

    private static let renamingWords: Set<String> = [
        "WITH", "TABLE", "VALUES", "JSON_TABLE", "CALL", "EXECUTE", "UNION", "INTERSECT", "EXCEPT",
    ]

    static func readsTableColumnsDirectly(_ statement: String) -> Bool {
        // The server runs an executable comment's body, and in `/*!50000SELECT` the version digits glue to the keyword.
        guard !executableCommentOpeners.contains(where: { statement.range(of: $0, options: .caseInsensitive) != nil })
        else { return false }
        var selects = 0
        var word = ""
        for scalar in statement.unicodeScalars {
            if scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
                continue
            }
            guard admits(&word, selects: &selects) else { return false }
        }
        return admits(&word, selects: &selects)
    }

    private static func admits(_ word: inout String, selects: inout Int) -> Bool {
        defer { word = "" }
        guard !word.isEmpty else { return true }
        let keyword = word.uppercased()
        if keyword == "SELECT" {
            selects += 1
            return selects == 1
        }
        return !renamingWords.contains(keyword)
    }
}
