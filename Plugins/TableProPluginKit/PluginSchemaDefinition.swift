//
//  PluginSchemaDefinition.swift
//  TableProPluginKit
//

import Foundation

/// One role's hold on one privilege over a schema, as the server reports it.
///
/// The grantee is the role's own name rather than a `PluginPrincipalRef`, because a schema ACL
/// names roles that the principal list may not carry: `PUBLIC` is a pseudo-role every engine
/// spells differently, and a grant can outlive the role that received it on engines that allow it.
public struct PluginSchemaGrant: Hashable, Sendable {
    public let grantee: String
    public let privilege: String
    public let isGrantable: Bool

    public init(grantee: String, privilege: String, isGrantable: Bool = false) {
        self.grantee = grantee
        self.privilege = privilege
        self.isGrantable = isGrantable
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
public struct PluginSchemaDetails: Hashable, Sendable {
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

    public var definition: PluginSchemaDefinition {
        PluginSchemaDefinition(name: name, owner: owner, comment: comment, grants: grants)
    }
}
