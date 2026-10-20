//
//  DatabaseObjectToolEligibility.swift
//  TablePro
//

import Foundation

/// Which of the per-object commands (Show DDL, Copy DDL, Refresh Materialized View, Edit Comment,
/// Drop Type) apply to a row. The sidebar and the menu bar ask the same functions, so the two can
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

        static let none = Support()

        @MainActor
        static func of(_ driver: DatabaseDriver?) -> Support {
            guard let driver else { return .none }
            let commentable = TableInfo.TableType.allCases.filter { type in
                driver.objectCommentStatement(name: "t", objectType: type.rawValue, schema: "s", comment: nil) != nil
            }
            let droppable = UserDefinedTypeInfo.Kind.allCases.filter { kind in
                driver.generateDropTypeSQL(type: UserDefinedTypeInfo(name: "t", kind: kind, schema: "s")) != nil
            }
            return Support(
                canRefreshMaterializedViews: driver.refreshMaterializedViewStatement(
                    name: "t", schema: "s", concurrently: false
                ) != nil,
                commentableTypes: Set(commentable),
                droppableTypeKinds: Set(droppable)
            )
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
}
