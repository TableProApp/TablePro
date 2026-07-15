//
//  PluginGrantGrouping.swift
//  TableProPluginKit
//
//  Collapses a flat grant list into one group per target object. Column-scoped grants
//  fold onto their parent table so a driver can emit
//  GRANT SELECT (a, b), UPDATE (a) ON TABLE t TO r as a single statement.
//

import Foundation

public struct PluginColumnPrivilege: Equatable, Sendable {
    public let privilege: String
    public let columns: [String]

    public init(privilege: String, columns: [String]) {
        self.privilege = privilege
        self.columns = columns
    }
}

public struct PluginGrantGroup: Equatable, Sendable {
    public let scope: PluginPrivilegeScope
    public let privileges: [String]
    public let columnPrivileges: [PluginColumnPrivilege]
    public let isGrantable: Bool

    public init(
        scope: PluginPrivilegeScope,
        privileges: [String],
        columnPrivileges: [PluginColumnPrivilege],
        isGrantable: Bool
    ) {
        self.scope = scope
        self.privileges = privileges
        self.columnPrivileges = columnPrivileges
        self.isGrantable = isGrantable
    }
}

public enum PluginGrantGrouping {
    public static func group(_ grants: [PluginGrantInfo]) -> [PluginGrantGroup] {
        var order: [PluginPrivilegeScope] = []
        var wholeObject: [PluginPrivilegeScope: [String]] = [:]
        var byColumn: [PluginPrivilegeScope: [String: [String]]] = [:]
        var grantable: Set<PluginPrivilegeScope> = []

        for grant in grants {
            let target = targetScope(for: grant.scope)
            if wholeObject[target] == nil, byColumn[target] == nil {
                order.append(target)
            }
            if grant.isGrantable {
                grantable.insert(target)
            }

            if let column = grant.scope.columnName {
                var privileges = byColumn[target] ?? [:]
                var columns = privileges[grant.privilege] ?? []
                if !columns.contains(column) {
                    columns.append(column)
                }
                privileges[grant.privilege] = columns
                byColumn[target] = privileges
            } else {
                var privileges = wholeObject[target] ?? []
                if !privileges.contains(grant.privilege) {
                    privileges.append(grant.privilege)
                }
                wholeObject[target] = privileges
            }
        }

        return order.map { scope in
            let columnPrivileges = (byColumn[scope] ?? [:])
                .sorted { $0.key < $1.key }
                .map { PluginColumnPrivilege(privilege: $0.key, columns: $0.value) }

            return PluginGrantGroup(
                scope: scope,
                privileges: wholeObject[scope] ?? [],
                columnPrivileges: columnPrivileges,
                isGrantable: grantable.contains(scope)
            )
        }
    }

    private static func targetScope(for scope: PluginPrivilegeScope) -> PluginPrivilegeScope {
        guard case let .column(database, schema, table, _) = scope else { return scope }
        return .table(database: database, schema: schema, table: table)
    }
}
