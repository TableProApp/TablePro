//
//  PluginSchemaDefinition.swift
//  TableProPluginKit
//

import Foundation

/// Who a schema privilege was granted to.
///
/// A named role and the all-users pseudo-group are different things that a string cannot keep
/// apart: PostgreSQL allows a quoted role literally called `public`, so deciding by name renders a
/// role-specific grant as `TO PUBLIC` and widens it to every user on the server. The distinction
/// comes from the ACL's own grantee id, which is zero for the group and never zero for a role.
/// Frozen because the case set is genuinely closed and an exhaustive switch over it is what the
/// whole type exists for: a grantee in a SQL ACL is the all-users group or one named role, and
/// there is no third kind for a future engine to add. A non-frozen enum would force
/// `@unknown default` at every render site, which is where the string-comparison bug lived.
@frozen
public enum PluginSchemaGrantee: Hashable, Sendable {
    case role(String)
    case publicGroup

    public var displayName: String {
        switch self {
        case .role(let name): name
        case .publicGroup: "PUBLIC"
        }
    }

    public var roleName: String? {
        guard case .role(let name) = self else { return nil }
        return name
    }
}

/// One hold on one privilege over a schema, as the server reports it.
///
/// `grantor` is carried rather than dropped because `REVOKE` only removes what the executing role
/// granted. PostgreSQL keeps a separate ACL entry per grantor, so two roles granting `USAGE` to the
/// same grantee produce two entries, and revoking as one of them leaves the other in force. A model
/// that collapsed them reported the access as removed while it was still there.
public struct PluginSchemaGrant: Hashable, Sendable {
    public let grantee: PluginSchemaGrantee
    public let privilege: String
    public let isGrantable: Bool
    public let grantor: String?

    public init(
        grantee: PluginSchemaGrantee,
        privilege: String,
        isGrantable: Bool = false,
        grantor: String? = nil
    ) {
        self.grantee = grantee
        self.privilege = privilege
        self.isGrantable = isGrantable
        self.grantor = grantor
    }
}

/// What a schema should become: the target state a create or an edit is asked for.
///
/// A nil field means "the engine's default" on create and "leave it alone" on edit, which is not
/// the same as an empty string: an empty comment clears the comment, and an empty owner is never
/// valid. `grants` is the full intended set for the privileges the engine declares, so the caller
/// diffs it against `PluginSchemaDetails.grants` rather than sending a blanket revoke.
public struct PluginSchemaDefinition: Hashable, Sendable {
    public let name: String
    public let owner: String?
    public let comment: String?
    public let grants: [PluginSchemaGrant]

    public init(
        name: String,
        owner: String? = nil,
        comment: String? = nil,
        grants: [PluginSchemaGrant] = []
    ) {
        self.name = name
        self.owner = owner
        self.comment = comment
        self.grants = grants
    }
}

/// A schema as it exists on the server right now, read immediately before an edit is generated so
/// the diff is against what is really there.
///
/// `currentRole` is the role the connection authenticated as, which is what decides whether a grant
/// can be revoked at all: the editor offers a cell only where that role is the grantor.
public struct PluginSchemaDetails: Hashable, Sendable {
    public let name: String
    public let owner: String?
    public let comment: String?
    public let grants: [PluginSchemaGrant]
    public let currentRole: String?

    public init(
        name: String,
        owner: String? = nil,
        comment: String? = nil,
        grants: [PluginSchemaGrant] = [],
        currentRole: String? = nil
    ) {
        self.name = name
        self.owner = owner
        self.comment = comment
        self.grants = grants
        self.currentRole = currentRole
    }

    public var definition: PluginSchemaDefinition {
        PluginSchemaDefinition(name: name, owner: owner, comment: comment, grants: grants)
    }
}
