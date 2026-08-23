//
//  StructureDiffEngine.swift
//  TablePro
//
//  Compares parsed structure metadata between two connections and produces the
//  SchemaChange list that would make the target match the source.
//  Structure is never compared as DDL text: driver-rendered DDL varies by
//  formatting and system-generated names, which reports identical objects as
//  different.
//

import Foundation

internal struct StructureDiffEngine {
    internal let options: StructureCompareOptions

    internal init(options: StructureCompareOptions = .default) {
        self.options = options
    }

    internal func compare(
        source: [TableStructureSnapshot],
        target: [TableStructureSnapshot]
    ) -> StructureDiffReport {
        let targetByKey = indexByMatchKey(target)

        var results: [TableDiffResult] = []
        var handled: Set<String> = []

        for snapshot in source {
            let key = options.matchKey(name: snapshot.name, schema: snapshot.schema)
            handled.insert(key)
            guard let counterpart = targetByKey[key] else {
                results.append(TableDiffResult(
                    tableName: snapshot.name,
                    schema: snapshot.schema,
                    status: .onlyInSource
                ))
                continue
            }
            results.append(compareTable(source: snapshot, target: counterpart))
        }

        for snapshot in target where !handled.contains(options.matchKey(name: snapshot.name, schema: snapshot.schema)) {
            results.append(TableDiffResult(
                tableName: snapshot.name,
                schema: snapshot.schema,
                status: .onlyInTarget
            ))
        }

        let sorted = results.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        return StructureDiffReport(results: sorted)
    }

    internal func compareTable(
        source: TableStructureSnapshot,
        target: TableStructureSnapshot
    ) -> TableDiffResult {
        var changes: [SchemaChange] = []
        var notes: [String] = []

        changes.append(contentsOf: columnChanges(source: source, target: target))
        changes.append(contentsOf: primaryKeyChanges(source: source, target: target))

        let indexOutcome = indexChanges(source: source, target: target)
        changes.append(contentsOf: indexOutcome.changes)
        notes.append(contentsOf: indexOutcome.notes)

        let foreignKeyOutcome = foreignKeyChanges(source: source, target: target)
        changes.append(contentsOf: foreignKeyOutcome.changes)
        notes.append(contentsOf: foreignKeyOutcome.notes)

        notes.append(contentsOf: columnOrderNotes(source: source, target: target))
        notes.append(contentsOf: tableOptionNotes(source: source, target: target))

        let status: TableDiffStatus = (changes.isEmpty && notes.isEmpty) ? .identical : .differs
        return TableDiffResult(
            tableName: source.name,
            schema: source.schema,
            status: status,
            changes: changes,
            notes: notes
        )
    }

    private func indexByMatchKey(_ snapshots: [TableStructureSnapshot]) -> [String: TableStructureSnapshot] {
        Dictionary(
            snapshots.map { (options.matchKey(name: $0.name, schema: $0.schema), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func columnOrderNotes(
        source: TableStructureSnapshot,
        target: TableStructureSnapshot
    ) -> [String] {
        guard !options.ignoreColumnOrder else { return [] }
        let sourceOrder = source.columns.map { options.matchKey($0.name) }
        let targetOrder = target.columns.map { options.matchKey($0.name) }
        guard sourceOrder != targetOrder, Set(sourceOrder) == Set(targetOrder) else { return [] }
        return [String(localized: "Column order differs. No statement is generated for reordering columns.")]
    }

    private func tableOptionNotes(
        source: TableStructureSnapshot,
        target: TableStructureSnapshot
    ) -> [String] {
        var notes: [String] = []
        if let sourceEngine = source.engine, let targetEngine = target.engine,
           options.matchKey(sourceEngine) != options.matchKey(targetEngine) {
            notes.append(String(
                format: String(localized: "Storage engine differs: %@ on source, %@ on target."),
                sourceEngine, targetEngine
            ))
        }
        guard !options.ignoreCollationAndCharset else { return notes }
        if let sourceCollation = source.collation, let targetCollation = target.collation,
           options.matchKey(sourceCollation) != options.matchKey(targetCollation) {
            notes.append(String(
                format: String(localized: "Table collation differs: %@ on source, %@ on target."),
                sourceCollation, targetCollation
            ))
        }
        return notes
    }
}
