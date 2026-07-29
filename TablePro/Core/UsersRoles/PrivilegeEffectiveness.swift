import Foundation
import TableProPluginKit

enum PrivilegeEffectiveness: Equatable {
    case direct
    case viaScope(PluginPrivilegeScope)
    case viaRole(name: String, isAutomatic: Bool)
    case notEffective

    var isEffective: Bool {
        self != .notEffective
    }
}

struct PrivilegeInheritanceContext {
    let grantsByPrincipal: [PluginPrincipalRef: Set<PrincipalGrantKey>]
    let roleClosure: [String]
    let inheritsAutomatically: Bool
    let cascades: (PluginPrivilegeScope, PluginPrivilegeScope) -> Bool

    init(
        grantsByPrincipal: [PluginPrincipalRef: Set<PrincipalGrantKey>],
        roleClosure: [String],
        inheritsAutomatically: Bool,
        cascades: @escaping (PluginPrivilegeScope, PluginPrivilegeScope) -> Bool
    ) {
        self.grantsByPrincipal = grantsByPrincipal
        self.roleClosure = roleClosure
        self.inheritsAutomatically = inheritsAutomatically
        self.cascades = cascades
    }
}

enum PrivilegeEffectivenessResolver {
    static func resolve(
        privilege: String,
        scope: PluginPrivilegeScope,
        directGrants: Set<PrincipalGrantKey>,
        context: PrivilegeInheritanceContext
    ) -> PrivilegeEffectiveness {
        if directGrants.contains(PrincipalGrantKey(privilege: privilege, scope: scope)) {
            return .direct
        }
        if let ancestor = cascadingAncestor(
            privilege: privilege,
            scope: scope,
            grants: directGrants,
            cascades: context.cascades
        ) {
            return .viaScope(ancestor)
        }

        for role in context.roleClosure {
            let ref = PluginPrincipalRef(name: role)
            guard let roleGrants = context.grantsByPrincipal[ref] else { continue }

            if roleGrants.contains(PrincipalGrantKey(privilege: privilege, scope: scope))
                || cascadingAncestor(
                    privilege: privilege,
                    scope: scope,
                    grants: roleGrants,
                    cascades: context.cascades
                ) != nil {
                return .viaRole(name: role, isAutomatic: context.inheritsAutomatically)
            }
        }
        return .notEffective
    }

    private static func cascadingAncestor(
        privilege: String,
        scope: PluginPrivilegeScope,
        grants: Set<PrincipalGrantKey>,
        cascades: (PluginPrivilegeScope, PluginPrivilegeScope) -> Bool
    ) -> PluginPrivilegeScope? {
        var candidate = scope.parent
        while let ancestor = candidate {
            let key = PrincipalGrantKey(privilege: privilege, scope: ancestor)
            if grants.contains(key), cascades(ancestor, scope) {
                return ancestor
            }
            candidate = ancestor.parent
        }
        return nil
    }

    static func roleClosure(
        for principal: PluginPrincipalRef,
        principals: [PluginPrincipalInfo]
    ) -> [String] {
        let membershipByName = Dictionary(
            principals.map { ($0.ref.name, $0.memberOf) },
            uniquingKeysWith: { first, _ in first }
        )

        var visited: Set<String> = [principal.name]
        var frontier = membershipByName[principal.name] ?? []
        var closure: [String] = []

        while let role = frontier.popLast() {
            guard visited.insert(role).inserted else { continue }
            closure.append(role)
            frontier.append(contentsOf: membershipByName[role] ?? [])
        }
        return closure
    }
}
