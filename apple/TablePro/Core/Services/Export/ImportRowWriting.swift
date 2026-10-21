//
//  ImportRowWriting.swift
//  TablePro
//

import Foundation

internal enum ImportWriteMode: String, CaseIterable, Identifiable, Sendable {
    case insert
    case update
    case upsert
    case insertSkippingExisting

    internal var id: String { rawValue }

    internal var label: String {
        switch self {
        case .insert: return String(localized: "Insert")
        case .update: return String(localized: "Update")
        case .upsert: return String(localized: "Insert or Update")
        case .insertSkippingExisting: return String(localized: "Insert, Skip Existing")
        }
    }

    internal var matchesExistingRows: Bool {
        self != .insert
    }

    internal var updatesMatchedRows: Bool {
        self == .update || self == .upsert
    }
}

internal struct ImportMatchKey: Hashable, Identifiable, Sendable {
    internal let indexName: String?
    internal let columns: [String]

    internal var id: [String] { columns }

    internal var isPrimaryKey: Bool { indexName == nil }

    internal var label: String {
        let list = columns.joined(separator: ", ")
        guard let indexName else {
            return String(format: String(localized: "Primary Key (%@)"), list)
        }
        return "\(indexName) (\(list))"
    }

    // A partial or expression index leaves the plain columns free to repeat, so it cannot pick out one row.
    internal static func options(columns: [ColumnInfo], indexes: [IndexInfo]) -> [ImportMatchKey] {
        let exact = Set(columns.map(\.name))
        // A spelling two columns share once case is folded names neither: PostgreSQL keeps "ID" and "id" apart.
        let folded = Dictionary(grouping: columns.map(\.name), by: { $0.lowercased() })
            .compactMapValues { $0.count == 1 ? $0.first : nil }
        func tableColumns(_ indexColumns: [String]) -> [String]? {
            let resolved = indexColumns.compactMap { exact.contains($0) ? $0 : folded[$0.lowercased()] }
            return !resolved.isEmpty && resolved.count == indexColumns.count ? resolved : nil
        }

        var keys: [ImportMatchKey] = []
        let flagged = columns.filter(\.isPrimaryKey).map(\.name)
        if let primary = indexes.first(where: \.isPrimary).flatMap({ tableColumns($0.columns) })
            ?? (flagged.isEmpty ? nil : flagged) {
            keys.append(ImportMatchKey(indexName: nil, columns: primary))
        }
        for index in indexes where index.isUnique && !index.isPrimary && index.isValid && index.whereClause == nil {
            guard (index.expressions ?? []).isEmpty,
                  let keyColumns = tableColumns(index.columns),
                  !keys.contains(where: { Set($0.columns) == Set(keyColumns) }) else { continue }
            keys.append(ImportMatchKey(indexName: index.name, columns: keyColumns))
        }
        return keys
    }
}

internal struct ImportRowWriting: Equatable, Sendable {
    internal let mode: ImportWriteMode
    internal let keyColumns: [String]

    internal static let insert = ImportRowWriting(mode: .insert, keyColumns: [])
}

internal enum ImportRowWritingProblem: Equatable {
    case noKey
    case unmappedKeyColumns([String])
    case nothingToUpdate

    internal static func of(
        mode: ImportWriteMode,
        key: ImportMatchKey?,
        mappedColumns: [String]
    ) -> ImportRowWritingProblem? {
        guard mode.matchesExistingRows else { return nil }
        guard let key else { return .noKey }
        let mapped = Set(mappedColumns)
        let missing = key.columns.filter { !mapped.contains($0) }
        guard missing.isEmpty else { return .unmappedKeyColumns(missing) }
        if mode.updatesMatchedRows, mapped.subtracting(key.columns).isEmpty {
            return .nothingToUpdate
        }
        return nil
    }

    internal var message: String {
        switch self {
        case .noKey:
            return String(localized: "This table has no primary key or unique index to match rows on.")
        case .unmappedKeyColumns(let columns):
            return String(
                format: String(localized: "Map a field to %@ to match rows on it."),
                columns.joined(separator: ", ")
            )
        case .nothingToUpdate:
            return String(localized: "Map a field to a column outside the key to have something to update.")
        }
    }
}

// Counted per row as it lands, so a row the database refused is in none of them.
internal struct ImportRowTally: Equatable, Sendable {
    internal let mode: ImportWriteMode
    internal var inserted = 0
    internal var updated = 0
    // Matched no row, so Update left it out.
    internal var unmatched = 0
    // Matched a row left as it was: Insert, Skip Existing, or a row with no value outside the key.
    internal var existing = 0

    internal init(mode: ImportWriteMode) {
        self.mode = mode
    }

    internal var matched: Int { updated + existing }
    internal var skipped: Int { unmatched + existing }

    internal func summaryLines(failed: Int) -> [String] {
        var lines = [String(format: String(localized: "Inserted: %@"), inserted.formatted())]
        if mode.matchesExistingRows {
            lines = [
                String(format: String(localized: "Matched: %@"), matched.formatted()),
                String(format: String(localized: "Updated: %@"), updated.formatted()),
                String(format: String(localized: "Inserted: %@"), inserted.formatted()),
                String(format: String(localized: "Skipped: %@"), skipped.formatted()),
            ]
        }
        if failed > 0 {
            lines.append(String(format: String(localized: "Failed: %@"), failed.formatted()))
        }
        return lines
    }
}
