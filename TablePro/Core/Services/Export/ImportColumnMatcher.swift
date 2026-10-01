//
//  ImportColumnMatcher.swift
//  TablePro
//

import Foundation

/// A row can be unticked while still naming a column, so the two are kept apart.
internal struct ImportFieldChoice: Equatable, Sendable {
    var include: Bool
    var column: String?

    static let skipped = ImportFieldChoice(include: false, column: nil)

    var mappedColumn: String? {
        include ? column : nil
    }
}

/// Only departures from the name match are stored, so a column the table gains later is still found
/// by name instead of staying skipped.
internal enum ImportMappingOverride: Codable, Equatable, Sendable {
    case column(String)
    case skip

    init(mappedColumn: String?) {
        guard let mappedColumn else {
            self = .skip
            return
        }
        self = .column(mappedColumn)
    }

    var choice: ImportFieldChoice {
        switch self {
        case .column(let column):
            return ImportFieldChoice(include: true, column: column)
        case .skip:
            return .skipped
        }
    }
}

/// Unlike `TableColumnMatcher`, exact matches come before case-insensitive ones and a column goes to
/// one field at most, because the sheet refuses two fields mapped to one column.
internal enum ImportColumnMatcher {
    static func byName(fields: [String], columns: [String]) -> [ImportFieldChoice] {
        resolve(fields: fields, columns: columns, preferring: [])
    }

    static func byPosition(fields: [String], columns: [String]) -> [ImportFieldChoice] {
        fields.indices.map { index in
            guard index < columns.count else { return .skipped }
            return ImportFieldChoice(include: true, column: columns[index])
        }
    }

    /// Each tier is settled for every field before the next starts, so a higher tier wins a column
    /// whatever the field order. A choice that can no longer be honoured falls through to the name match.
    static func resolve(
        fields: [String],
        columns: [String],
        preferring tiers: [[String: ImportFieldChoice]]
    ) -> [ImportFieldChoice] {
        var claimed = Set<String>()
        var choices = [ImportFieldChoice?](repeating: nil, count: fields.count)

        for tier in tiers {
            for (index, field) in fields.enumerated() where choices[index] == nil {
                guard let preferred = choice(for: field, among: fields, in: tier) else { continue }
                guard let wanted = preferred.column else {
                    choices[index] = preferred
                    continue
                }
                let available = matchingColumn(wanted, in: columns, excluding: preferred.include ? claimed : [])
                guard let column = available else {
                    if !preferred.include {
                        choices[index] = .skipped
                    }
                    continue
                }
                if preferred.include {
                    claimed.insert(column)
                }
                choices[index] = ImportFieldChoice(include: preferred.include, column: column)
            }
        }

        for (index, field) in fields.enumerated() where choices[index] == nil {
            guard columns.contains(field), !claimed.contains(field) else { continue }
            claimed.insert(field)
            choices[index] = ImportFieldChoice(include: true, column: field)
        }

        for (index, field) in fields.enumerated() where choices[index] == nil {
            guard let column = matchingColumn(field, in: columns, excluding: claimed) else {
                choices[index] = .skipped
                continue
            }
            claimed.insert(column)
            choices[index] = ImportFieldChoice(include: true, column: column)
        }

        return choices.map { $0 ?? .skipped }
    }

    static func applying(
        _ overrides: [String: ImportMappingOverride],
        fields: [String],
        columns: [String]
    ) -> [ImportFieldChoice] {
        resolve(fields: fields, columns: columns, preferring: [overrides.mapValues(\.choice)])
    }

    /// The fields whose current choice is a remembered override the name match would not have made.
    static func restoredFields(
        _ overrides: [String: ImportMappingOverride],
        fields: [String],
        columns: [String],
        choices: [ImportFieldChoice]
    ) -> Set<String> {
        let automatic = byName(fields: fields, columns: columns)
        var restored = Set<String>()
        for (index, field) in fields.enumerated() where index < choices.count {
            let current = choices[index].mappedColumn
            guard let override = choice(for: field, among: fields, in: overrides),
                  current.map(normalized) == override.choice.mappedColumn.map(normalized),
                  current != automatic[index].mappedColumn else { continue }
            restored.insert(field)
        }
        return restored
    }

    static func overrides(
        fields: [String],
        columns: [String],
        choices: [ImportFieldChoice]
    ) -> [String: ImportMappingOverride] {
        let automatic = byName(fields: fields, columns: columns)
        var overrides: [String: ImportMappingOverride] = [:]
        for (index, field) in fields.enumerated() where index < choices.count {
            let mapped = choices[index].mappedColumn
            guard mapped != automatic[index].mappedColumn else { continue }
            overrides[field] = ImportMappingOverride(mappedColumn: mapped)
        }
        return overrides
    }

    /// Entries for fields this file does not hold are kept, so several layouts into one table all come
    /// back. A header respelled only by case takes over its one differently-cased entry.
    static func merging(
        _ overrides: [String: ImportMappingOverride],
        forFields fields: [String],
        into saved: [String: ImportMappingOverride]
    ) -> [String: ImportMappingOverride] {
        let exactKeys = Set(fields).intersection(saved.keys)
        var merged = saved.filter { !exactKeys.contains($0.key) }
        for (folded, spellings) in Dictionary(grouping: fields, by: normalized) {
            guard spellings.count == 1, let field = spellings.first, !exactKeys.contains(field) else { continue }
            let variants = merged.keys.filter { normalized($0) == folded }
            guard variants.count == 1, let variant = variants.first else { continue }
            merged.removeValue(forKey: variant)
        }
        for (field, override) in overrides {
            merged[field] = override
        }
        return merged
    }

    /// A differently-cased entry is used only when that is unambiguous on both sides: `Email` and `email`
    /// can be two fields of one file.
    private static func choice<Value>(for field: String, among fields: [String], in prior: [String: Value]) -> Value? {
        if let exact = prior[field] { return exact }
        let folded = normalized(field)
        guard fields.filter({ normalized($0) == folded }).count == 1 else { return nil }
        let variants = prior.keys.filter { normalized($0) == folded }
        guard variants.count == 1, let variant = variants.first else { return nil }
        return prior[variant]
    }

    private static func matchingColumn(_ name: String, in columns: [String], excluding claimed: Set<String>) -> String? {
        if columns.contains(name), !claimed.contains(name) {
            return name
        }
        return columns.first { column in
            !claimed.contains(column) && column.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased()
    }
}
