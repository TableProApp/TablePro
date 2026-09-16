//
//  SchemaFormRules.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One grantee's row in the privileges table: the role, and which privileges it holds.
///
/// `revocable` is the subset this connection's role can actually take away. PostgreSQL's `REVOKE`
/// removes only what the executing role granted, so a privilege another role granted stays checked
/// and uneditable: a revoke there succeeds, changes nothing, and would be reported as done while
/// the access remained.
struct SchemaGranteeRow: Identifiable, Hashable {
    let grantee: PluginSchemaGrantee
    var granted: Set<String>
    var grantable: Set<String>
    var revocable: Set<String>

    var id: String {
        switch grantee {
        case .publicGroup: "\u{1}public"
        case .role(let name): "role\u{1}\(name)"
        }
    }

    var displayName: String { grantee.displayName }

    func holds(_ privilege: String) -> Bool { granted.contains(privilege) }

    /// A held privilege is editable only where it can be revoked. An unheld one always is, because
    /// a new grant is made by the connected role and needs no prior authority.
    func canEdit(_ privilege: String) -> Bool {
        granted.contains(privilege) ? revocable.contains(privilege) : true
    }
}

/// Validation and diffing for the schema sheets, kept out of the views so both the rules and the
/// statements they produce are testable without a connection or a server.
enum SchemaFormRules {
    /// A name the user could plausibly have meant. Everything else, including a duplicate the
    /// sheet did not know about and a name the engine reserves, is the server's to refuse: it
    /// knows its own rules and its message is better than a guess.
    enum NameProblem: Equatable {
        case empty
        case duplicate

        var message: String {
            switch self {
            case .empty:
                String(localized: "Enter a name.")
            case .duplicate:
                String(localized: "A schema with this name already exists.")
            }
        }
    }

    /// Leading and trailing whitespace is trimmed rather than rejected, because it is almost
    /// always a paste artefact and a quoted identifier would preserve it silently.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func problem(
        with name: String,
        existing: [String],
        ignoring current: String? = nil
    ) -> NameProblem? {
        let candidate = normalized(name)
        guard !candidate.isEmpty else { return .empty }
        if let current, candidate == current { return nil }
        let clash = existing.contains { $0 == candidate }
        return clash ? .duplicate : nil
    }

    static func rows(
        from details: PluginSchemaDetails,
        privileges: [PluginPrivilegeDescriptor]
    ) -> [SchemaGranteeRow] {
        let names = Set(privileges.map(\.name))
        var byGrantee: [PluginSchemaGrantee: SchemaGranteeRow] = [:]
        var conflictingGrantors: Set<String> = []
        for grant in details.grants where names.contains(grant.privilege) {
            var row = byGrantee[grant.grantee]
                ?? SchemaGranteeRow(grantee: grant.grantee, granted: [], grantable: [], revocable: [])
            let key = "\(row.id)\u{1}\(grant.privilege)"
            /// A second grantor for the same cell takes it out of reach: the connected role can
            /// revoke its own entry and the other would still be in force.
            if row.granted.contains(grant.privilege) {
                conflictingGrantors.insert(key)
            }
            row.granted.insert(grant.privilege)
            if grant.isGrantable { row.grantable.insert(grant.privilege) }
            if grant.grantor != nil, grant.grantor == details.currentRole {
                row.revocable.insert(grant.privilege)
            }
            byGrantee[grant.grantee] = row
        }
        return byGrantee.values
            .map { row in
                var resolved = row
                resolved.revocable = row.revocable.filter {
                    !conflictingGrantors.contains("\(row.id)\u{1}\($0)")
                }
                return resolved
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func grants(from rows: [SchemaGranteeRow]) -> [PluginSchemaGrant] {
        rows.flatMap { row in
            row.granted.sorted().map { privilege in
                PluginSchemaGrant(
                    grantee: row.grantee,
                    privilege: privilege,
                    isGrantable: row.grantable.contains(privilege)
                )
            }
        }
    }

    /// Whether anything at all changed. A Save that would emit no statement is not offered, so the
    /// user never confirms an operation that does nothing and never sees an empty preview.
    static func hasChanges(from current: PluginSchemaDetails, to target: PluginSchemaDefinition) -> Bool {
        if current.name != target.name { return true }
        if let owner = target.owner, !owner.isEmpty, owner != current.owner { return true }
        if current.comment != target.comment { return true }
        return privilegeKeys(current.grants) != privilegeKeys(target.grants)
    }

    /// Compared on what the editor can express, which is the grantee, the privilege and the grant
    /// option. Comparing whole grants would report a change whenever the grantor differed, which
    /// the editor never sets and the server always reports.
    private static func privilegeKeys(_ grants: [PluginSchemaGrant]) -> Set<String> {
        Set(grants.map { "\($0.grantee.displayName)\u{1}\($0.privilege)\u{1}\($0.isGrantable)" })
    }
}
