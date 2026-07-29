import Foundation
import TableProPluginKit

struct PrincipalGrantKey: Hashable {
    let privilege: String
    let scope: PluginPrivilegeScope
}

enum PrincipalChange {
    case create(PluginPrincipalDefinition)
    case alter(old: PluginPrincipalDefinition, new: PluginPrincipalDefinition)
    case setPassword(ref: PluginPrincipalRef, password: String)
    case modifyGrants(PluginPrincipalChangeSet)
    case drop(ref: PluginPrincipalRef, options: PluginPrincipalDropOptions)

    var principal: PluginPrincipalRef {
        switch self {
        case let .create(definition): definition.ref
        case let .alter(old, _): old.ref
        case let .setPassword(ref, _): ref
        case let .modifyGrants(changeSet): changeSet.principal
        case let .drop(ref, _): ref
        }
    }

    var isDestructive: Bool {
        switch self {
        case .drop:
            true
        case let .modifyGrants(changeSet):
            !changeSet.grantsToRemove.isEmpty
        case .create, .alter, .setPassword:
            false
        }
    }

    var executionRank: Int {
        switch self {
        case .create: 0
        case .alter: 1
        case .setPassword: 2
        case .modifyGrants: 3
        case .drop: 4
        }
    }
}

extension PluginPrincipalRef {
    var displayName: String {
        guard let host, !host.isEmpty else { return name }
        return "\(name)@\(host)"
    }
}
