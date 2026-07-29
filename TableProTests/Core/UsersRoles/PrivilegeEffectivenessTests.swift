//
//  PrivilegeEffectivenessTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Privilege effectiveness")
struct PrivilegeEffectivenessTests {
    private let table = PluginPrivilegeScope.table(database: "app", schema: "public", table: "orders")
    private let column = PluginPrivilegeScope.column(
        database: "app",
        schema: "public",
        table: "orders",
        column: "total"
    )

    private let mysqlCascade: (PluginPrivilegeScope, PluginPrivilegeScope) -> Bool = {
        $0.contains($1)
    }

    private let postgresCascade: (PluginPrivilegeScope, PluginPrivilegeScope) -> Bool = { ancestor, descendant in
        guard case .table = ancestor, case .column = descendant else { return false }
        return ancestor.contains(descendant)
    }

    private func context(
        cascade: @escaping (PluginPrivilegeScope, PluginPrivilegeScope) -> Bool,
        roles: [String] = [],
        grants: [PluginPrincipalRef: Set<PrincipalGrantKey>] = [:],
        inheritsAutomatically: Bool = true
    ) -> PrivilegeInheritanceContext {
        PrivilegeInheritanceContext(
            grantsByPrincipal: grants,
            roleClosure: roles,
            inheritsAutomatically: inheritsAutomatically,
            cascades: cascade
        )
    }

    @Test("A direct grant outranks every inherited source")
    func directWins() {
        let result = PrivilegeEffectivenessResolver.resolve(
            privilege: "SELECT",
            scope: table,
            directGrants: [PrincipalGrantKey(privilege: "SELECT", scope: table)],
            context: context(cascade: mysqlCascade)
        )
        #expect(result == .direct)
    }

    @Test("MySQL cascades a database grant down to a table")
    func mysqlCascadesFromDatabase() {
        let result = PrivilegeEffectivenessResolver.resolve(
            privilege: "SELECT",
            scope: table,
            directGrants: [PrincipalGrantKey(privilege: "SELECT", scope: .database("app"))],
            context: context(cascade: mysqlCascade)
        )
        #expect(result == .viaScope(.database("app")))
    }

    @Test("PostgreSQL does not cascade a database grant to a table")
    func postgresDoesNotCascadeFromDatabase() {
        let result = PrivilegeEffectivenessResolver.resolve(
            privilege: "SELECT",
            scope: table,
            directGrants: [PrincipalGrantKey(privilege: "SELECT", scope: .database("app"))],
            context: context(cascade: postgresCascade)
        )
        #expect(result == .notEffective)
    }

    @Test("PostgreSQL does cascade a table grant to a column")
    func postgresCascadesToColumn() {
        let result = PrivilegeEffectivenessResolver.resolve(
            privilege: "SELECT",
            scope: column,
            directGrants: [PrincipalGrantKey(privilege: "SELECT", scope: table)],
            context: context(cascade: postgresCascade)
        )
        #expect(result == .viaScope(table))
    }

    @Test("A privilege held by a granted role is reported as inherited")
    func inheritsFromRole() {
        let role = PluginPrincipalRef(name: "app_ro")
        let result = PrivilegeEffectivenessResolver.resolve(
            privilege: "SELECT",
            scope: table,
            directGrants: [],
            context: context(
                cascade: postgresCascade,
                roles: ["app_ro"],
                grants: [role: [PrincipalGrantKey(privilege: "SELECT", scope: table)]]
            )
        )
        #expect(result == .viaRole(name: "app_ro", isAutomatic: true))
    }

    @Test("A NOINHERIT role is reported as needing SET ROLE")
    func reportsNonAutomaticInheritance() {
        let role = PluginPrincipalRef(name: "app_ro")
        let result = PrivilegeEffectivenessResolver.resolve(
            privilege: "SELECT",
            scope: table,
            directGrants: [],
            context: context(
                cascade: postgresCascade,
                roles: ["app_ro"],
                grants: [role: [PrincipalGrantKey(privilege: "SELECT", scope: table)]],
                inheritsAutomatically: false
            )
        )
        #expect(result == .viaRole(name: "app_ro", isAutomatic: false))
    }

    @Test("Role closure is transitive and terminates on a cycle")
    func buildsTransitiveClosure() {
        let principals = [
            PluginPrincipalInfo(ref: PluginPrincipalRef(name: "alice"), memberOf: ["dev"]),
            PluginPrincipalInfo(ref: PluginPrincipalRef(name: "dev"), memberOf: ["readonly"]),
            PluginPrincipalInfo(ref: PluginPrincipalRef(name: "readonly"), memberOf: ["alice"])
        ]
        let closure = PrivilegeEffectivenessResolver.roleClosure(
            for: PluginPrincipalRef(name: "alice"),
            principals: principals
        )
        #expect(Set(closure) == ["dev", "readonly"])
    }
}

@Suite("Scope summary")
struct ScopeSummaryTests {
    private let descriptors = [
        PluginPrivilegeDescriptor(name: "SELECT", label: "Select"),
        PluginPrivilegeDescriptor(name: "INSERT", label: "Insert")
    ]

    @Test("A database we cannot browse is never reported as having no privileges")
    func browsingRestrictedIsDistinct() {
        let summary = ScopeSummary.make(
            granted: ["CONNECT"],
            grantable: descriptors,
            descendantCount: 0,
            hasGrantOption: false,
            isBrowsingRestricted: true
        )
        #expect(summary == .browsingRestricted(direct: ["CONNECT"]))
        #expect(summary != .none)
    }

    @Test("Every grantable privilege granted collapses to All")
    func collapsesToAll() {
        let summary = ScopeSummary.make(
            granted: ["SELECT", "INSERT"],
            grantable: descriptors,
            descendantCount: 0,
            hasGrantOption: false,
            isBrowsingRestricted: false
        )
        #expect(summary == .all(count: 2))
    }

    @Test("Descendant grants surface when the scope itself has none")
    func reportsDescendants() {
        let summary = ScopeSummary.make(
            granted: [],
            grantable: descriptors,
            descendantCount: 3,
            hasGrantOption: false,
            isBrowsingRestricted: false
        )
        #expect(summary == .descendantsOnly(count: 3))
    }

    @Test("Nothing grantable at this level is distinct from nothing granted")
    func distinguishesNotGrantable() {
        #expect(
            ScopeSummary.make(
                granted: [],
                grantable: [],
                descendantCount: 0,
                hasGrantOption: false,
                isBrowsingRestricted: false
            ) == .notGrantable
        )
    }
}

@Suite("Password generator")
struct PasswordGeneratorTests {
    @Test("Generates the requested length from an unambiguous alphabet")
    func generatesLength() {
        let password = PasswordGenerator.generate(length: 24)
        #expect(password.count == 24)
        #expect(!password.contains(where: { "0O1lI".contains($0) }))
    }

    @Test("Successive passwords differ")
    func generatesUniqueValues() {
        let generated = Set((0 ..< 200).map { _ in PasswordGenerator.generate() })
        #expect(generated.count == 200)
    }
}

@Suite("Privilege categories")
struct PrivilegeCategoryTests {
    @Test("Known keys map to localized titles in a stable order")
    func mapsKnownKeys() {
        #expect(PrivilegeCategory.resolve(PluginPrivilegeCategoryKey.data).sortOrder == 0)
        #expect(PrivilegeCategory.resolve(PluginPrivilegeCategoryKey.structure).sortOrder == 1)
        #expect(PrivilegeCategory.resolve(PluginPrivilegeCategoryKey.administration).isCollapsedByDefault)
        #expect(PrivilegeCategory.resolve(PluginPrivilegeCategoryKey.dynamic).isCollapsedByDefault)
    }

    @Test("A missing key becomes Other, an unknown key is shown verbatim")
    func handlesUnknownKeys() {
        #expect(PrivilegeCategory.resolve(nil) == .other)
        #expect(PrivilegeCategory.resolve("").key == "other")
        #expect(PrivilegeCategory.resolve("future").title == "future")
    }

    @Test("Grouping sorts categories and keeps their privileges")
    func groupsDescriptors() {
        let grouped = PrivilegeCategory.group([
            PluginPrivilegeDescriptor(
                name: "SUPER",
                label: "Super",
                category: PluginPrivilegeCategoryKey.administration
            ),
            PluginPrivilegeDescriptor(
                name: "SELECT",
                label: "Select",
                category: PluginPrivilegeCategoryKey.data
            )
        ])

        #expect(grouped.map(\.category.key) == [
            PluginPrivilegeCategoryKey.data,
            PluginPrivilegeCategoryKey.administration
        ])
        #expect(grouped[0].descriptors.map(\.name) == ["SELECT"])
    }
}
