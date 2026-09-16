//
//  SchemaFormRules.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One grantee's row in the privileges table: the role, and which privileges it holds.
struct SchemaGranteeRow: Identifiable, Hashable {
    let grantee: String
    var granted: Set<String>
    var grantable: Set<String>

    var id: String { grantee }

    func holds(_ privilege: String) -> Bool { granted.contains(privilege) }
    func canGrant(_ privilege: String) -> Bool { grantable.contains(privilege) }
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
        from grants: [PluginSchemaGrant],
        privileges: [PluginPrivilegeDescriptor]
    ) -> [SchemaGranteeRow] {
        let names = Set(privileges.map(\.name))
        var byGrantee: [String: SchemaGranteeRow] = [:]
        for grant in grants where names.contains(grant.privilege) {
            var row = byGrantee[grant.grantee]
                ?? SchemaGranteeRow(grantee: grant.grantee, granted: [], grantable: [])
            row.granted.insert(grant.privilege)
            if grant.isGrantable { row.grantable.insert(grant.privilege) }
            byGrantee[grant.grantee] = row
        }
        return byGrantee.values.sorted { $0.grantee.localizedStandardCompare($1.grantee) == .orderedAscending }
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
        return Set(current.grants) != Set(target.grants)
    }
}
