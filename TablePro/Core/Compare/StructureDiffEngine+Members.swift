//
//  StructureDiffEngine+Members.swift
//  TablePro
//
//  Column, primary key, index and foreign key comparison.
//  Indexes and foreign keys are matched on structure rather than on name, so a
//  system-generated name difference never reports an object as changed.
//

import Foundation

internal extension StructureDiffEngine {
    struct MemberOutcome {
        internal let changes: [SchemaChange]
        internal let notes: [String]
    }

    func columnChanges(
        source: TableStructureSnapshot,
        target: TableStructureSnapshot
    ) -> [SchemaChange] {
        let targetByKey = Dictionary(
            target.columns.map { (options.matchKey($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sourceKeys = Set(source.columns.map { options.matchKey($0.name) })

        var changes: [SchemaChange] = []
        for column in source.columns {
            guard let existing = targetByKey[options.matchKey(column.name)] else {
                changes.append(.addColumn(column))
                continue
            }
            guard columnSignature(column) != columnSignature(existing) else { continue }
            changes.append(.modifyColumn(old: existing, new: column))
        }
        for column in target.columns where !sourceKeys.contains(options.matchKey(column.name)) {
            changes.append(.deleteColumn(column))
        }
        return changes
    }

    func primaryKeyChanges(
        source: TableStructureSnapshot,
        target: TableStructureSnapshot
    ) -> [SchemaChange] {
        let sourceKey = source.primaryKeyColumns
        let targetKey = target.primaryKeyColumns
        guard options.columnListKey(sourceKey) != options.columnListKey(targetKey) else { return [] }
        return [.modifyPrimaryKey(old: targetKey, new: sourceKey)]
    }

    func indexChanges(
        source: TableStructureSnapshot,
        target: TableStructureSnapshot
    ) -> MemberOutcome {
        let sourceIndexes = source.indexes.filter { !$0.isPrimary }
        let targetIndexes = target.indexes.filter { !$0.isPrimary }

        var remaining = targetIndexes
        var changes: [SchemaChange] = []
        var notes: [String] = []

        for index in sourceIndexes {
            let signature = indexSignature(index)
            guard let position = remaining.firstIndex(where: { indexSignature($0) == signature }) else {
                changes.append(.addIndex(index))
                continue
            }
            let matched = remaining.remove(at: position)
            guard options.matchKey(matched.name) != options.matchKey(index.name) else { continue }
            notes.append(String(
                format: String(localized: "Index %@ matches %@ on the target but the names differ."),
                index.name, matched.name
            ))
        }
        for index in remaining {
            changes.append(.deleteIndex(index))
        }
        return MemberOutcome(changes: changes, notes: notes)
    }

    func foreignKeyChanges(
        source: TableStructureSnapshot,
        target: TableStructureSnapshot
    ) -> MemberOutcome {
        var remaining = target.foreignKeys
        var changes: [SchemaChange] = []
        var notes: [String] = []

        for foreignKey in source.foreignKeys {
            let signature = foreignKeySignature(foreignKey)
            guard let position = remaining.firstIndex(where: { foreignKeySignature($0) == signature }) else {
                changes.append(.addForeignKey(foreignKey))
                continue
            }
            let matched = remaining.remove(at: position)
            guard options.matchKey(matched.name) != options.matchKey(foreignKey.name) else { continue }
            notes.append(String(
                format: String(localized: "Foreign key %@ matches %@ on the target but the names differ."),
                foreignKey.name, matched.name
            ))
        }
        for foreignKey in remaining {
            changes.append(.deleteForeignKey(foreignKey))
        }
        return MemberOutcome(changes: changes, notes: notes)
    }
}

private extension StructureDiffEngine {
    func columnSignature(_ column: EditableColumnDefinition) -> String {
        var parts: [String] = [
            options.matchKey(column.name),
            options.normalizedType(column.dataType),
            String(column.isNullable),
            String(column.autoIncrement),
            String(column.unsigned),
            options.normalizedText(column.defaultValue) ?? "",
            options.normalizedText(column.onUpdate) ?? "",
            options.normalizedText(strippedExtra(column.extra)) ?? ""
        ]
        if !options.ignoreCollationAndCharset {
            parts.append(options.matchKey(column.charset ?? ""))
            parts.append(options.matchKey(column.collation ?? ""))
        }
        if !options.ignoreCommentsAndOwners {
            parts.append(options.normalizedText(column.comment) ?? "")
        }
        return parts.joined(separator: "\u{1F}")
    }

    func indexSignature(_ index: EditableIndexDefinition) -> String {
        var parts: [String] = [
            options.columnListKey(index.columns),
            String(index.isUnique),
            options.matchKey(index.type.rawValue),
            options.normalizedText(index.whereClause) ?? ""
        ]
        let prefixes = index.columnPrefixes
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { "\(options.matchKey($0.key)):\($0.value)" }
        parts.append(prefixes.joined(separator: ","))
        return parts.joined(separator: "\u{1F}")
    }

    func foreignKeySignature(_ foreignKey: EditableForeignKeyDefinition) -> String {
        [
            options.columnListKey(foreignKey.columns),
            options.matchKey(foreignKey.referencedTable),
            options.columnListKey(foreignKey.referencedColumns),
            options.matchKey(foreignKey.referencedSchema ?? ""),
            foreignKey.onDelete.rawValue,
            foreignKey.onUpdate.rawValue
        ].joined(separator: "\u{1F}")
    }

    func strippedExtra(_ extra: String?) -> String? {
        guard let extra else { return nil }
        guard options.ignoreAutoIncrementSeed else { return extra }
        return extra.replacingOccurrences(
            of: "auto_increment=[0-9]+",
            with: "auto_increment",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}
