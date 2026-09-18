//
//  SQLStringLiteralPrefix.swift
//  TablePro
//

import Foundation

/// What an engine puts in front of a string literal that carries user text.
///
/// SQL Server is the one engine that needs anything: a plain `'…'` is a `varchar` literal, so the
/// server converts it to the database collation's code page while it parses the batch, and on a
/// non-Unicode collation every character outside that page becomes `?`. That happens whatever the
/// column is, so `WHERE n = '日本語'` on an `NVARCHAR` column matches nothing the user meant.
/// `N'…'` is an `nvarchar` literal and is converted by nothing; on ASCII the two are equal.
///
/// A number, an identifier and a `0x` binary literal never come through here.
enum SQLStringLiteralPrefix {
    static func forDatabaseType(_ databaseType: DatabaseType?) -> String {
        guard let databaseType else { return "" }
        switch databaseType {
        case .mssql:
            return "N"
        default:
            return ""
        }
    }
}
