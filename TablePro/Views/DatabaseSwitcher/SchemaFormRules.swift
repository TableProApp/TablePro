//
//  SchemaFormRules.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One grantee's row in the privileges table: the role, and which privileges it holds.
struct SchemaGranteeRow: Identifiable, Hashable {
    let grantee: PluginSchemaGrantee
    var granted: Set<String>
    var grantable: Set<String>

    /// Privileges the server holds for this grantee that the connected role cannot take away,
    /// because another role granted them. PostgreSQL's `REVOKE` removes only what the executing
    /// role granted, so a revoke here succeeds, changes nothing, and would be reported as done
    /// while the access remained.
    ///
    /// Read from the server once, at load, and never from the form afterwards. Deciding this from
    /// the live `granted` set instead latched every box the user ticked: the tick moved the
    /// privilege into `granted`, a privilege that does not exist on the server yet can have no
    /// grantor, so the cell went uneditable and could never be cleared again.
    let locked: Set<String>

    var id: String {
        switch grantee {
        case .publicGroup: "\u{1}public"
        case .role(let name): "role\u{1}\(name)"
        }
    }

    var displayName: String { grantee.displayName }

    func holds(_ privilege: String) -> Bool { granted.contains(privilege) }

    func canEdit(_ privilege: String) -> Bool { !locked.contains(privilege) }
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
        var granted: [PluginSchemaGrantee: Set<String>] = [:]
        var grantable: [PluginSchemaGrantee: Set<String>] = [:]
        /// Counted per grantor so two of them on one cell can be told from one. Either case puts
        /// the cell out of reach: with two, revoking the connected role's entry leaves the other
        /// in force; with one that is not the connected role, the revoke does nothing at all.
        var grantors: [PluginSchemaGrantee: [String: Set<String>]] = [:]

        for grant in details.grants where names.contains(grant.privilege) {
            granted[grant.grantee, default: []].insert(grant.privilege)
            if grant.isGrantable { grantable[grant.grantee, default: []].insert(grant.privilege) }
            grantors[grant.grantee, default: [:]][grant.privilege, default: []]
                .insert(grant.grantor ?? "")
        }

        return granted.keys
            .map { grantee -> SchemaGranteeRow in
                let held = granted[grantee] ?? []
                let locked = held.filter { privilege in
                    let issuers = grantors[grantee]?[privilege] ?? []
                    guard issuers.count == 1, let issuer = issuers.first else { return true }
                    guard let currentRole = details.currentRole, !currentRole.isEmpty else { return true }
                    return issuer != currentRole
                }
                return SchemaGranteeRow(
                    grantee: grantee,
                    granted: held,
                    grantable: grantable[grantee] ?? [],
                    locked: locked
                )
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
