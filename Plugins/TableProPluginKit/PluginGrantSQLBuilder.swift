//
//  PluginGrantSQLBuilder.swift
//  TableProPluginKit
//
//  GRANT and REVOKE share one shape across dialects: a privilege clause, a target, and a
//  grantee. Only the target and grantee rendering are dialect-specific, so drivers supply
//  those and the clause (including column lists) is built here once.
//

import Foundation

public struct PluginGrantSQLBuilder {
    private let grantee: String
    private let quoteIdentifier: (String) -> String
    private let target: (PluginPrivilegeScope) -> String?

    public init(
        grantee: String,
        quoteIdentifier: @escaping (String) -> String,
        target: @escaping (PluginPrivilegeScope) -> String?
    ) {
        self.grantee = grantee
        self.quoteIdentifier = quoteIdentifier
        self.target = target
    }

    public func grantStatements(_ grants: [PluginGrantInfo]) -> [String] {
        statements(grants) { clause, target, group in
            let grantOption = group.isGrantable ? " WITH GRANT OPTION" : ""
            return "GRANT \(clause) ON \(target) TO \(grantee)\(grantOption)"
        }
    }

    public func revokeStatements(_ grants: [PluginGrantInfo]) -> [String] {
        statements(grants) { clause, target, _ in
            "REVOKE \(clause) ON \(target) FROM \(grantee)"
        }
    }

    private func statements(
        _ grants: [PluginGrantInfo],
        render: (String, String, PluginGrantGroup) -> String
    ) -> [String] {
        PluginGrantGrouping.group(grants).compactMap { group in
            guard let target = target(group.scope),
                  let clause = privilegeClause(for: group) else { return nil }
            return render(clause, target, group)
        }
    }

    public func privilegeClause(for group: PluginGrantGroup) -> String? {
        var parts = group.privileges.compactMap(PluginPrivilegeName.sanitized)

        parts += group.columnPrivileges.compactMap { entry -> String? in
            guard let privilege = PluginPrivilegeName.sanitized(entry.privilege),
                  !entry.columns.isEmpty else { return nil }
            let columns = entry.columns.map(quoteIdentifier).joined(separator: ", ")
            return "\(privilege) (\(columns))"
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
