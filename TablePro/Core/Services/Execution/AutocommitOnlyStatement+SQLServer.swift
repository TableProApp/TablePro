//
//  AutocommitOnlyStatement+SQLServer.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

internal extension AutocommitOnlyStatement {
    /// From the T-SQL transaction locking and row versioning guide, which lists the statements an
    /// explicit transaction cannot hold: `CREATE`, `ALTER` and `DROP DATABASE`, the full-text
    /// catalog and index statements, `BACKUP`, `RESTORE` and `RECONFIGURE`. Unmeasured: there is no
    /// SQL Server here. The statements that begin `CREATE DATABASE` without being one, such as
    /// `CREATE DATABASE SCOPED CREDENTIAL`, keep the wrap.
    static func matchesSQLServer(_ statement: NSString, grammar: SQLLexicalGrammar) -> Bool {
        var cursor = SQLTokenCursor(statement, grammar: grammar)
        guard let keyword = cursor.next()?.word else { return false }
        switch keyword {
        case "RECONFIGURE":
            return true
        case "BACKUP":
            return backupTargets.contains(cursor.next()?.word ?? "")
        case "RESTORE":
            return restoreTargets.contains(cursor.next()?.word ?? "")
        case "CREATE", "ALTER", "DROP":
            return definesADatabaseOrFullTextObject(&cursor)
        default:
            return false
        }
    }
}

private extension AutocommitOnlyStatement {
    static let backupTargets: Set<String> = ["DATABASE", "LOG"]

    static let restoreTargets: Set<String> = [
        "DATABASE", "LOG", "HEADERONLY", "FILELISTONLY", "LABELONLY", "VERIFYONLY", "REWINDONLY"
    ]

    static let fullTextTargets: Set<String> = ["CATALOG", "INDEX"]

    /// The objects whose statements only start with `DATABASE`: a database-scoped configuration or
    /// credential, a database audit specification and a database encryption key are all ordinary
    /// statements an explicit transaction can hold.
    static let databaseScopedObjects: Set<String> = ["SCOPED", "AUDIT", "ENCRYPTION"]

    static func definesADatabaseOrFullTextObject(_ cursor: inout SQLTokenCursor) -> Bool {
        guard let object = cursor.next()?.word else { return false }
        if object == "FULLTEXT" { return fullTextTargets.contains(cursor.next()?.word ?? "") }
        guard object == "DATABASE" else { return false }
        guard let following = cursor.next()?.word else { return true }
        return !databaseScopedObjects.contains(following)
    }
}
