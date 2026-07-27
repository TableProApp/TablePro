//
//  SyncSafetyClassifier.swift
//  TablePro
//
//  Decides which generated statements are unsafe enough to be refused unless
//  the user allows them for a single run. Refusing by default keeps the preview
//  honest: nothing runs that the preview did not show as allowed.
//

import Foundation

internal struct SyncSafetyClassifier {
    internal func hazards(for change: SchemaChange) -> [SyncHazard] {
        switch change {
        case .deleteColumn(let column):
            return [SyncHazard(
                kind: .dataLoss,
                severity: .refusedByDefault,
                explanation: String(
                    format: String(localized: "Dropping column %@ permanently removes its data."),
                    column.name
                )
            )]
        case .modifyColumn(let old, let new):
            return modifyColumnHazards(old: old, new: new)
        case .modifyPrimaryKey:
            return [SyncHazard(
                kind: .primaryKeyChange,
                severity: .refusedByDefault,
                explanation: String(localized: "Changing the primary key rebuilds the table and can fail on duplicate values.")
            )]
        case .deleteIndex(let index):
            return [SyncHazard(
                kind: .tableRebuild,
                severity: .warning,
                explanation: String(
                    format: String(localized: "Dropping index %@ can slow existing queries."),
                    index.name
                )
            )]
        case .deleteForeignKey, .addForeignKey, .modifyForeignKey, .addColumn, .addIndex, .modifyIndex:
            return []
        }
    }

    internal func hazards(forDropping tableName: String) -> [SyncHazard] {
        [SyncHazard(
            kind: .dataLoss,
            severity: .refusedByDefault,
            explanation: String(
                format: String(localized: "Dropping table %@ permanently removes the table and all of its rows."),
                tableName
            )
        )]
    }

    private func modifyColumnHazards(
        old: EditableColumnDefinition,
        new: EditableColumnDefinition
    ) -> [SyncHazard] {
        var hazards: [SyncHazard] = []

        if let narrowing = TypeWidthComparison.classify(from: old.dataType, to: new.dataType),
           narrowing == .narrowing {
            hazards.append(SyncHazard(
                kind: .lossyTypeChange,
                severity: .refusedByDefault,
                explanation: String(
                    format: String(localized: "Changing %@ from %@ to %@ can truncate existing values."),
                    old.name, old.dataType, new.dataType
                )
            ))
        }

        if old.isNullable, !new.isNullable {
            hazards.append(SyncHazard(
                kind: .dataLoss,
                severity: .refusedByDefault,
                explanation: String(
                    format: String(localized: "Making %@ NOT NULL fails if any existing row holds NULL."),
                    old.name
                )
            ))
        }

        if normalized(old.collation) != normalized(new.collation)
            || normalized(old.charset) != normalized(new.charset) {
            hazards.append(SyncHazard(
                kind: .collationOrCharsetChange,
                severity: .warning,
                explanation: String(
                    format: String(localized: "Changing the collation of %@ can change sort order and uniqueness."),
                    old.name
                )
            ))
        }

        return hazards
    }

    private func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

internal enum TypeWidthComparison {
    internal enum Outcome {
        case widening
        case narrowing
        case equivalent
    }

    internal static func classify(from oldType: String, to newType: String) -> Outcome? {
        let old = parse(oldType)
        let new = parse(newType)
        guard old.base == new.base else { return .narrowing }
        guard let oldWidth = old.width, let newWidth = new.width else { return .equivalent }
        if newWidth > oldWidth { return .widening }
        if newWidth < oldWidth { return .narrowing }
        return .equivalent
    }

    private static func parse(_ type: String) -> (base: String, width: Int?) {
        let lowered = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let open = lowered.firstIndex(of: "("), let close = lowered.firstIndex(of: ")"), open < close else {
            return (lowered, nil)
        }
        let base = String(lowered[lowered.startIndex..<open])
        let inner = lowered[lowered.index(after: open)..<close]
        let firstComponent = inner.split(separator: ",").first.map(String.init) ?? ""
        return (base, Int(firstComponent.trimmingCharacters(in: .whitespaces)))
    }
}
