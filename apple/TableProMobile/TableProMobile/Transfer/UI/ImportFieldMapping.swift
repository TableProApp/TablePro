import Foundation

// The mapping of a file's fields onto an existing table's columns. The rules are the shared `ImportColumnMatcher`;
// this only keeps the sheet's current choice per field and what was saved for the table.
nonisolated struct ImportFieldMapping: Equatable, Sendable {
    nonisolated struct Row: Identifiable, Equatable, Sendable {
        let field: String
        var choice: ImportFieldChoice

        var id: String { field }
    }

    private(set) var columns: [String] = []
    private(set) var rows: [Row] = []
    private(set) var saved: [String: ImportMappingOverride] = [:]
    private(set) var showsSavedMapping = false

    var fields: [String] { rows.map(\.field) }

    var choices: [ImportFieldChoice] { rows.map(\.choice) }

    var columnMapping: [String: String] {
        var mapping: [String: String] = [:]
        for row in rows {
            guard let column = row.choice.mappedColumn else { continue }
            mapping[row.field] = column
        }
        return mapping
    }

    var hasMappedField: Bool {
        rows.contains { $0.choice.mappedColumn != nil }
    }

    var mapsOneColumnTwice: Bool {
        let targets = rows.compactMap { $0.choice.mappedColumn?.lowercased() }
        return Set(targets).count != targets.count
    }

    var canUseSavedMapping: Bool {
        guard !saved.isEmpty else { return false }
        let restored = ImportColumnMatcher.applying(saved, fields: fields, columns: columns)
        guard restored != choices else { return false }
        return !ImportColumnMatcher.restoredFields(saved, fields: fields, columns: columns, choices: restored).isEmpty
    }

    // What to remember for the table: only the departures from the name match.
    var overrides: [String: ImportMappingOverride] {
        ImportColumnMatcher.overrides(fields: fields, columns: columns, choices: choices)
    }

    // A reload of the same table keeps the choices made in the sheet, then the saved ones, then the name match.
    mutating func load(
        fields: [String],
        columns: [String],
        saved: [String: ImportMappingOverride],
        keepingChoices: Bool
    ) {
        var tiers = [saved.mapValues(\.choice)]
        if keepingChoices {
            let session = Dictionary(rows.map { ($0.field, $0.choice) }, uniquingKeysWith: { first, _ in first })
            tiers.insert(session, at: 0)
        }
        self.columns = columns
        self.saved = saved
        apply(ImportColumnMatcher.resolve(fields: fields, columns: columns, preferring: tiers), to: fields)
        showsSavedMapping = (keepingChoices ? showsSavedMapping : true) && appliesSavedChoice
    }

    mutating func clear() {
        columns = []
        rows = []
        saved = [:]
        showsSavedMapping = false
    }

    mutating func matchByName() {
        apply(ImportColumnMatcher.byName(fields: fields, columns: columns), to: fields)
        showsSavedMapping = false
    }

    mutating func matchByPosition() {
        apply(ImportColumnMatcher.byPosition(fields: fields, columns: columns), to: fields)
        showsSavedMapping = false
    }

    mutating func useSavedMapping() {
        apply(ImportColumnMatcher.applying(saved, fields: fields, columns: columns), to: fields)
        showsSavedMapping = appliesSavedChoice
    }

    // Nil is "Do not import".
    mutating func map(_ field: String, to column: String?) {
        guard let index = rows.firstIndex(where: { $0.field == field }) else { return }
        rows[index].choice = column.map { ImportFieldChoice(include: true, column: $0) } ?? .skipped
        showsSavedMapping = false
    }

    private var appliesSavedChoice: Bool {
        !ImportColumnMatcher.restoredFields(saved, fields: fields, columns: columns, choices: choices).isEmpty
    }

    private mutating func apply(_ choices: [ImportFieldChoice], to fields: [String]) {
        rows = zip(fields, choices).map { Row(field: $0, choice: $1) }
    }
}
