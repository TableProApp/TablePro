//
//  ColumnDefaultLiteral.swift
//  TablePro
//

import Foundation

/// A column default that states NULL outright, as opposed to one the server computes.
///
/// Its value is already known, so a new row sends NULL rather than leaving the column to the
/// server, and a column that stops accepting NULL cannot keep it as its default.
internal enum ColumnDefaultLiteral {
    static func isNull(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("NULL") == .orderedSame
    }
}
