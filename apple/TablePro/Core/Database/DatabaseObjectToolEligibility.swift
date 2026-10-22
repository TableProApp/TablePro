//
//  DatabaseObjectToolEligibility.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Which of the per-object commands (Show DDL, Copy DDL, Refresh Materialized View, Edit Comment,
/// New Type, Rename Type, Drop Type) apply to a row. The sidebar and the menu bar ask the same functions, so the two can
/// never offer a command to a different set of objects; the sidebar omits what the menu bar disables.
enum DatabaseObjectToolEligibility {
    /// What the connection's driver can do, read once per menu build rather than per item.
    ///
    /// Derived by asking the driver's own statement hooks, so a driver cannot declare a capability
    /// it has no statement for.
    struct Support: Equatable {
        var canRefreshMaterializedViews = false
        var commentableTypes: Set<TableInfo.TableType> = []
        var droppableTypeKinds: Set<UserDefinedTypeInfo.Kind> = []
        var cascadingDropTypeKinds: Set<UserDefinedTypeInfo.Kind> = []
        var renameableTypeKinds: Set<UserDefinedTypeInfo.Kind> = []
        var creatableTypeKinds: Set<UserDefinedTypeInfo.Kind> = []
        var canSetSequenceValues = false
        var canAlterSequences = false

        static let none = Support()

        @MainActor
        static func of(_ driver: DatabaseDriver?) -> Support {
            guard let driver else { return .none }
            let kinds = UserDefinedTypeInfo.Kind.allCases
            let probe = { (kind: UserDefinedTypeInfo.Kind) in UserDefinedTypeInfo(name: "t", kind: kind, schema: "s") }
            let sequenceProbe = PluginSequenceDetails(
                name: "s", schema: "s", dataType: nil, startValue: 1, increment: 1, minValue: 1, maxValue: 10,
                cacheSize: 1, cycles: false, lastValue: nil, nextValue: nil, ownedByTable: nil, ownedByColumn: nil
            )
            let changed = PluginSequenceSettings(increment: 2, minValue: 1, maxValue: 10, cacheSize: 1, cycles: false)
            return Support(
                canRefreshMaterializedViews: driver.refreshMaterializedViewStatement(
                    name: "t", schema: "s", concurrently: false
                ) != nil,
                commentableTypes: commentableTypes(of: driver),
                droppableTypeKinds: Set(kinds.filter { driver.generateDropTypeSQL(type: probe($0), cascade: false) != nil }),
                cascadingDropTypeKinds: Set(kinds.filter { driver.generateDropTypeSQL(type: probe($0), cascade: true) != nil }),
                renameableTypeKinds: Set(kinds.filter {
                    driver.alterUserDefinedTypeStatements(type: probe($0), change: .rename(to: "u")) != nil
                }),
                creatableTypeKinds: Set(kinds.filter { kind in
                    UserTypeCreationDraft.probeDefinition(kind: kind).flatMap {
                        driver.createUserDefinedTypeStatements($0)
                    } != nil
                }),
                canSetSequenceValues: driver.sequenceNextValueStatement(for: sequenceProbe, nextValue: .value(1)) != nil,
                canAlterSequences: driver.alterSequenceStatement(for: sequenceProbe, settings: changed) != nil
            )
        }

        static func commentableTypes(of driver: DatabaseDriver) -> Set<TableInfo.TableType> {
            Set(TableInfo.TableType.allCases.filter { type in
                driver.objectCommentStatement(name: "t", objectType: type.rawValue, schema: "s", comment: nil) != nil
            })
        }
    }

    /// A view's source is its definition rather than its columns, which is what the DDL viewer
    /// shows. Offered read-only too: reading a definition changes nothing.
    static func canShowDDL(_ type: TableInfo.TableType?) -> Bool {
        guard let type else { return false }
        return DatabaseObjectKind(tableType: type) != nil
    }

    static func canRefresh(_ type: TableInfo.TableType?, support: Support, isReadOnly: Bool) -> Bool {
        guard !isReadOnly, type == .materializedView else { return false }
        return support.canRefreshMaterializedViews
    }

    static func canEditComment(_ type: TableInfo.TableType?, support: Support, isReadOnly: Bool) -> Bool {
        guard !isReadOnly, let type else { return false }
        return support.commentableTypes.contains(type)
    }

    static func canDropType(_ kind: UserDefinedTypeInfo.Kind, support: Support, isReadOnly: Bool) -> Bool {
        !isReadOnly && support.droppableTypeKinds.contains(kind)
    }

    static func canRenameType(_ kind: UserDefinedTypeInfo.Kind, support: Support, isReadOnly: Bool) -> Bool {
        !isReadOnly && support.renameableTypeKinds.contains(kind)
    }

    static func canCreateType(support: Support, isReadOnly: Bool) -> Bool {
        !isReadOnly && !support.creatableTypeKinds.isEmpty
    }

    static func canSetSequenceValue(_ type: TableInfo.TableType?, support: Support, isReadOnly: Bool) -> Bool {
        !isReadOnly && type == .sequence && support.canSetSequenceValues
    }

    static func canEditSequence(_ type: TableInfo.TableType?, support: Support, isReadOnly: Bool) -> Bool {
        !isReadOnly && type == .sequence && support.canAlterSequences
    }
}
