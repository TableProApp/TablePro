//
//  RowImportMapping.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

/// The mapping of a row import into an existing table, held outside the sheet so its rules are testable.
@MainActor
internal final class RowImportMapping: ObservableObject {
    internal struct Row: Identifiable {
        let field: PluginImportField
        var choice: ImportFieldChoice

        var id: String { field.name }
    }

    @Published internal private(set) var columns: [String] = []
    @Published internal var rows: [Row] = []
    @Published internal private(set) var table: TableScope?

    /// Set when a table is picked or the saved mapping is put back, never by a reload, so a failed
    /// import does not announce the user's own mapping as restored.
    @Published internal private(set) var showsSavedMapping = false
    @Published private var saved: [String: ImportMappingOverride] = [:]

    /// Cleared with the rows, so picking a table again always reads it again.
    internal private(set) var loadedRead: AnyHashable?

    private let store: ImportColumnMappingStore

    internal init(store: ImportColumnMappingStore = .shared) {
        self.store = store
    }

    internal var fields: [String] {
        rows.map(\.field.name)
    }

    internal var choices: [ImportFieldChoice] {
        rows.map(\.choice)
    }

    internal var columnMapping: [String: String] {
        var mapping: [String: String] = [:]
        for row in rows {
            guard let column = row.choice.mappedColumn else { continue }
            mapping[row.field.name] = column
        }
        return mapping
    }

    internal var hasMappedField: Bool {
        rows.contains { $0.choice.mappedColumn != nil }
    }

    internal var mapsOneColumnTwice: Bool {
        let targets = rows.compactMap { $0.choice.mappedColumn?.lowercased() }
        return Set(targets).count != targets.count
    }

    /// Only when the saved mapping covers a field of this file.
    internal var canUseSavedMapping: Bool {
        guard !saved.isEmpty else { return false }
        let restored = savedChoices
        guard restored != choices else { return false }
        return !ImportColumnMatcher.restoredFields(saved, fields: fields, columns: columns, choices: restored).isEmpty
    }

    internal func clear() {
        table = nil
        columns = []
        rows = []
        saved = [:]
        showsSavedMapping = false
        loadedRead = nil
    }

    /// A reload of the same table prefers this sheet's choices, then the saved ones, then the name match.
    internal func load(
        fields: [PluginImportField],
        columns: [String],
        for scope: TableScope,
        read: AnyHashable? = nil
    ) {
        let remembered = store.overrides(for: scope)
        let reloading = table == scope
        var tiers = [remembered.mapValues(\.choice)]
        if reloading {
            let session = Dictionary(rows.map { ($0.field.name, $0.choice) }, uniquingKeysWith: { first, _ in first })
            tiers.insert(session, at: 0)
        }
        table = scope
        saved = remembered
        self.columns = columns
        let names = fields.map(\.name)
        apply(ImportColumnMatcher.resolve(fields: names, columns: columns, preferring: tiers), to: fields)
        showsSavedMapping = (reloading ? showsSavedMapping : true) && appliesSavedChoice
        loadedRead = read
    }

    internal func matchByName() {
        apply(ImportColumnMatcher.byName(fields: fields, columns: columns))
        showsSavedMapping = false
    }

    internal func matchByPosition() {
        apply(ImportColumnMatcher.byPosition(fields: fields, columns: columns))
        showsSavedMapping = false
    }

    internal func useSavedMapping() {
        apply(savedChoices)
        showsSavedMapping = appliesSavedChoice
    }

    internal func setAllIncluded(_ include: Bool) {
        for index in rows.indices {
            rows[index].choice.include = include
        }
    }

    /// Called when an import starts, whether it succeeds or not, with the plan it runs: a mapping built
    /// by hand is the costliest part of the sheet to redo.
    internal func remember(
        fields: [String],
        columns: [String],
        columnMapping: [String: String],
        in scope: TableScope
    ) {
        let choices = fields.map { field in
            columnMapping[field].map { ImportFieldChoice(include: true, column: $0) } ?? .skipped
        }
        let overrides = ImportColumnMatcher.overrides(fields: fields, columns: columns, choices: choices)
        store.remember(overrides, forFields: fields, in: scope)
        if table == scope {
            saved = store.overrides(for: scope)
        }
    }

    private var appliesSavedChoice: Bool {
        !ImportColumnMatcher.restoredFields(saved, fields: fields, columns: columns, choices: choices).isEmpty
    }

    private var savedChoices: [ImportFieldChoice] {
        ImportColumnMatcher.applying(saved, fields: fields, columns: columns)
    }

    private func apply(_ choices: [ImportFieldChoice]) {
        apply(choices, to: rows.map(\.field))
    }

    private func apply(_ choices: [ImportFieldChoice], to fields: [PluginImportField]) {
        rows = zip(fields, choices).map { Row(field: $0, choice: $1) }
    }
}
