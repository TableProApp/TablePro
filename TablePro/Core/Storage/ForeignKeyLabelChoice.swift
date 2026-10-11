//
//  ForeignKeyLabelChoice.swift
//  TablePro
//

import Foundation

/// What the reader has said about a referenced table's label columns.
///
/// Three states, because "I have not chosen" and "I chose to show no label" are different answers
/// and only one of them should let the heuristic run. Encoding the second as an absent key made it
/// identical to the first, so **None** was forgotten the moment the picker was reopened.
///
/// A choice carries a list rather than one name, because a parent row's identity often spans
/// several columns: a table whose `UNIQUE` constraint is `(descrizione, marchio)` reads as six
/// identical rows under either column alone.
///
/// The stored form is a one-byte sentinel plus a payload. `0xFE` and `0xFF` are the sentinels
/// because no Unicode scalar's UTF-8 contains either byte, checked over all 1,114,112 of them, so
/// neither can begin a column name. An empty value would not do: SQLite accepts
/// `create table t("" integer)`, so `""` is a name a reader can really pick, while PostgreSQL and
/// MariaDB refuse it. Keep the sentinels, and do not "simplify" this to an empty-`Data` check.
///
/// Bare UTF-8 with no sentinel is the single-name form every existing choice is written in, and it
/// stays readable forever. It is a read path only: a choice written from here always carries the
/// `0xFE` sentinel, whatever its count, so one meaning has one spelling on the way out.
internal enum ForeignKeyLabelChoice: Equatable, Sendable {
    case unset
    case noLabel
    case columns([String])

    private static let noLabelSentinel: UInt8 = 0xFF
    private static let listSentinel: UInt8 = 0xFE

    /// Choosing nothing is choosing **None**, so an emptied chooser is remembered rather than
    /// handed back to the heuristic. Duplicates collapse to the first mention, because the same
    /// column twice would select it twice and read as a repeated value.
    internal init(columnNames: [String]) {
        var seen = Set<String>()
        let unique = columnNames.filter { seen.insert($0).inserted }
        self = unique.isEmpty ? .noLabel : .columns(unique)
    }

    internal init(storedData: Data?) {
        guard let storedData else {
            self = .unset
            return
        }
        guard let first = storedData.first else {
            self = .columns([""])
            return
        }
        if first == Self.noLabelSentinel, storedData.count == 1 {
            self = .noLabel
            return
        }
        if first == Self.listSentinel {
            let payload = Data(storedData.dropFirst())
            guard let names = try? JSONDecoder().decode([String].self, from: payload) else {
                self = .unset
                return
            }
            self = ForeignKeyLabelChoice(columnNames: names)
            return
        }
        guard let name = String(bytes: storedData, encoding: .utf8) else {
            self = .unset
            return
        }
        self = .columns([name])
    }

    internal var storedData: Data? {
        switch self {
        case .unset:
            return nil
        case .noLabel:
            return Data([Self.noLabelSentinel])
        case .columns(let names):
            guard !names.isEmpty, let payload = try? JSONEncoder().encode(names) else {
                return Data([Self.noLabelSentinel])
            }
            return Data([Self.listSentinel]) + payload
        }
    }

    internal var columnNames: [String] {
        guard case .columns(let names) = self else { return [] }
        return names
    }
}
