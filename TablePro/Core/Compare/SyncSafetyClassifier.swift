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
    /// The engine the script is written for, because a type's parameters only mean something on one:
    /// `TypeWidthComparison` says which readings differ.
    internal func hazards(for change: SchemaChange, typeFamily: SQLTypeFamily) -> [SyncHazard] {
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
            return modifyColumnHazards(old: old, new: new, typeFamily: typeFamily)
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
        case .deleteCheckConstraint(let constraint):
            return [SyncHazard(
                kind: .dataLoss,
                severity: .warning,
                explanation: String(
                    format: String(localized: "Dropping check constraint %@ stops it validating new rows."),
                    constraint.name
                )
            )]
        case .modifyCheckConstraint(let old, _):
            return [SyncHazard(
                kind: .tableRebuild,
                severity: .warning,
                explanation: String(
                    format: String(
                        localized: "Changing check constraint %@ re-checks every existing row and fails if any violates it."
                    ),
                    old.name
                )
            )]
        case .addCheckConstraint(let constraint):
            return [SyncHazard(
                kind: .tableRebuild,
                severity: .warning,
                explanation: String(
                    format: String(
                        localized: "Adding check constraint %@ scans the table and fails if any existing row violates it."
                    ),
                    constraint.name
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

    /// A view or a routine holds no rows, so dropping one is recoverable from the source and only
    /// warns. A materialized view does hold rows, so it is refused like a table. Either way a drop
    /// can break something that depends on it, which is what the second hazard says.
    internal func hazards(
        forDropping identity: CompareObjectIdentity,
        isReplacement: Bool,
        recreatesIndexes: Bool = false
    ) -> [SyncHazard] {
        var hazards: [SyncHazard] = []

        if identity.kind == .materializedView {
            hazards.append(SyncHazard(
                kind: .dataLoss,
                severity: .refusedByDefault,
                explanation: materializedViewDropExplanation(identity, recreatesIndexes: recreatesIndexes)
            ))
        }

        guard !isReplacement else {
            hazards.append(SyncHazard(
                kind: .notSupportedByTarget,
                severity: .warning,
                explanation: String(
                    format: String(
                        localized: "%1$@ %2$@ is dropped and recreated, so anything depending on it fails until it exists again."
                    ),
                    identity.kind.displayName, identity.displayName
                )
            ))
            return hazards
        }

        hazards.append(SyncHazard(
            kind: .dataLoss,
            severity: .refusedByDefault,
            explanation: String(
                format: String(localized: "Dropping %1$@ %2$@ removes it from the target."),
                identity.kind.displayName.lowercased(), identity.displayName
            )
        ))
        return hazards
    }

    internal func concurrentRefreshHazard(
        on identity: CompareObjectIdentity,
        from current: [EditableIndexDefinition],
        to resulting: [EditableIndexDefinition]
    ) -> SyncHazard? {
        guard identity.kind == .materializedView,
              ConcurrentRefreshIndexRule.allowsConcurrentRefresh(current),
              !ConcurrentRefreshIndexRule.allowsConcurrentRefresh(resulting)
        else { return nil }
        return SyncHazard(
            kind: .concurrentRefresh,
            severity: .warning,
            explanation: String(
                format: String(
                    localized: "%@ is left with no unique index a concurrent refresh can use, so REFRESH MATERIALIZED VIEW CONCURRENTLY fails on it."
                ),
                identity.displayName
            )
        )
    }

    private func materializedViewDropExplanation(_ identity: CompareObjectIdentity, recreatesIndexes: Bool) -> String {
        guard recreatesIndexes else {
            return String(
                format: String(
                    localized: "Dropping materialized view %@ discards its stored rows along with its indexes, comments and privileges."
                ),
                identity.displayName
            )
        }
        return String(
            format: String(
                localized: "Dropping materialized view %@ discards its stored rows, comments and privileges. The rows are computed again and the source's indexes are created on it."
            ),
            identity.displayName
        )
    }

    private func modifyColumnHazards(
        old: EditableColumnDefinition,
        new: EditableColumnDefinition,
        typeFamily: SQLTypeFamily
    ) -> [SyncHazard] {
        var hazards: [SyncHazard] = []

        if TypeWidthComparison.classify(from: old.dataType, to: new.dataType, family: typeFamily) == .narrowing {
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
