import Foundation
import TableProPluginKit

extension PrincipalChangeManager {
    func effectiveness(
        privilege: String,
        scope: PluginPrivilegeScope,
        for principal: PluginPrincipalRef
    ) -> PrivilegeEffectiveness {
        PrivilegeEffectivenessResolver.resolve(
            privilege: privilege,
            scope: scope,
            directGrants: resolvedGrantKeys(for: principal),
            context: inheritanceContext(for: principal)
        )
    }

    func inheritanceContext(for principal: PluginPrincipalRef) -> PrivilegeInheritanceContext {
        let closure = PrivilegeEffectivenessResolver.roleClosure(
            for: principal,
            principals: principals
        )
        var grantsByPrincipal: [PluginPrincipalRef: Set<PrincipalGrantKey>] = [:]
        for role in closure {
            let ref = PluginPrincipalRef(name: role)
            guard hasLoadedGrants(for: ref) else { continue }
            grantsByPrincipal[ref] = resolvedGrantKeys(for: ref)
        }

        return PrivilegeInheritanceContext(
            grantsByPrincipal: grantsByPrincipal,
            roleClosure: closure,
            inheritsAutomatically: inheritsAutomatically(principal),
            cascades: cascades
        )
    }

    func roleClosure(for principal: PluginPrincipalRef) -> [String] {
        PrivilegeEffectivenessResolver.roleClosure(for: principal, principals: principals)
    }

    private func inheritsAutomatically(_ principal: PluginPrincipalRef) -> Bool {
        guard let info = principals.first(where: { $0.ref == principal }) else { return true }
        guard let inherit = info.attributes.first(where: { $0.key == "INHERIT" }) else { return true }
        return inherit.isEnabled
    }

    func summary(
        at scope: PluginPrivilegeScope,
        for principal: PluginPrincipalRef,
        isBrowsingRestricted: Bool
    ) -> ScopeSummary {
        let granted = grantedPrivileges(at: scope, for: principal)
        let grantable = catalog?.privileges(for: scope) ?? []
        let hasGrantOption = granted.contains {
            isGrantable($0, scope: scope, for: principal)
        }

        return ScopeSummary.make(
            granted: granted,
            grantable: grantable,
            descendantCount: descendantGrantCount(under: scope, for: principal),
            hasGrantOption: hasGrantOption,
            isBrowsingRestricted: isBrowsingRestricted
        )
    }

    func sections(for scope: PluginPrivilegeScope) -> [PrivilegeSection] {
        let descriptors = catalog?.privileges(for: scope) ?? []
        return PrivilegeCategory.group(descriptors).map {
            PrivilegeSection(category: $0.category, descriptors: $0.descriptors)
        }
    }
}
