//
//  ForeignKeyLabelChoice.swift
//  TablePro
//

import Foundation

/// What the reader has said about a referenced table's label column.
///
/// Three states, because "I have not chosen" and "I chose to show no label" are different answers
/// and only one of them should let the heuristic run. Encoding the second as an absent key made it
/// identical to the first, so **None** was forgotten the moment the picker was reopened.
///
/// The stored form is the column name's UTF-8, which is what is already on disk, plus a one-byte
/// sentinel for `noLabel`. `0xFF` is the sentinel because no Unicode scalar's UTF-8 contains it,
/// checked over all 1,114,112 of them, so it can never be a column name. An empty value would not
/// do: SQLite accepts `create table t("" integer)`, so `""` is a name a reader can really pick,
/// while PostgreSQL and MariaDB refuse it. Keep the sentinel, and do not "simplify" this to an
/// empty-`Data` check.
internal enum ForeignKeyLabelChoice: Equatable, Sendable {
    case unset
    case noLabel
    case column(String)

    private static let noLabelSentinel = Data([0xFF])

    internal init(storedData: Data?) {
        guard let storedData else {
            self = .unset
            return
        }
        if storedData == Self.noLabelSentinel {
            self = .noLabel
            return
        }
        guard let name = String(bytes: storedData, encoding: .utf8) else {
            self = .unset
            return
        }
        self = .column(name)
    }

    internal var storedData: Data? {
        switch self {
        case .unset:
            return nil
        case .noLabel:
            return Self.noLabelSentinel
        case .column(let name):
            return Data(name.utf8)
        }
    }
}
