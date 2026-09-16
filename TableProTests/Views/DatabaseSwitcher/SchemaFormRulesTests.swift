//
//  SchemaFormRulesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Schema Form Rules")
struct SchemaFormRulesTests {
    private let privileges = [
        PluginPrivilegeDescriptor(name: "USAGE", label: "Usage"),
        PluginPrivilegeDescriptor(name: "CREATE", label: "Create")
    ]

    @Test("Surrounding whitespace is trimmed rather than quoted into the identifier")
    func trimsWhitespace() {
        #expect(SchemaFormRules.normalized("  app_data \n") == "app_data")
    }

    @Test("An empty or whitespace-only name is refused before it reaches the server")
    func refusesEmptyName() {
        #expect(SchemaFormRules.problem(with: "", existing: []) == .empty)
        #expect(SchemaFormRules.problem(with: "   ", existing: []) == .empty)
    }

    @Test("A name already in the list is refused")
    func refusesDuplicate() {
        #expect(SchemaFormRules.problem(with: "app_data", existing: ["public", "app_data"]) == .duplicate)
    }

    @Test("A schema keeping its own name is not a duplicate of itself")
    func ownNameIsNotADuplicate() {
        let problem = SchemaFormRules.problem(
            with: "app_data",
            existing: ["public", "app_data"],
            ignoring: "app_data"
        )
        #expect(problem == nil)
    }

    /// Case, reserved words and length are the server's to judge: it knows its own rules and its
    /// message beats a guess.
    @Test("A mixed-case name that differs only by case is not a duplicate")
    func caseIsNotADuplicate() {
        #expect(SchemaFormRules.problem(with: "App_Data", existing: ["app_data"]) == nil)
    }

    @Test("A reserved word and a non-ASCII name are left for the server to judge")
    func leavesReservedAndUnicodeToTheServer() {
        #expect(SchemaFormRules.problem(with: "select", existing: []) == nil)
        #expect(SchemaFormRules.problem(with: "スキーマ", existing: []) == nil)
    }

    private func details(
        _ grants: [PluginSchemaGrant],
        currentRole: String? = "admin"
    ) -> PluginSchemaDetails {
        PluginSchemaDetails(name: "app_data", grants: grants, currentRole: currentRole)
    }

    @Test("Grants become one row per grantee, sorted, with the grant option kept")
    func buildsRows() {
        let rows = SchemaFormRules.rows(
            from: details([
                PluginSchemaGrant(grantee: .role("reporting"), privilege: "USAGE", grantor: "admin"),
                PluginSchemaGrant(
                    grantee: .role("app_user"), privilege: "CREATE", isGrantable: true, grantor: "admin"
                ),
                PluginSchemaGrant(grantee: .role("app_user"), privilege: "USAGE", grantor: "admin")
            ]),
            privileges: privileges
        )
        #expect(rows.map(\.displayName) == ["app_user", "reporting"])
        #expect(rows[0].granted == ["USAGE", "CREATE"])
        #expect(rows[0].grantable == ["CREATE"])
        #expect(rows[1].granted == ["USAGE"])
    }

    /// PostgreSQL allows a quoted role literally named `public`. Deciding by name rendered a grant
    /// to that role as `TO PUBLIC` and handed it to every user on the server.
    @Test("A real role named public is a different grantee from the all-users group")
    func realPublicRoleIsNotTheGroup() {
        let rows = SchemaFormRules.rows(
            from: details([
                PluginSchemaGrant(grantee: .role("public"), privilege: "USAGE", grantor: "admin"),
                PluginSchemaGrant(grantee: .publicGroup, privilege: "CREATE", grantor: "admin")
            ]),
            privileges: privileges
        )
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.grantee)) == [.role("public"), .publicGroup])
        #expect(rows.first { $0.grantee == .role("public") }?.granted == ["USAGE"])
        #expect(rows.first { $0.grantee == .publicGroup }?.granted == ["CREATE"])
    }

    /// `REVOKE` removes only what the executing role granted, so a cell another role granted is
    /// not editable: the statement would succeed, change nothing, and be reported as done.
    @Test("A privilege another role granted is held but not editable")
    func foreignGrantIsNotEditable() {
        let rows = SchemaFormRules.rows(
            from: details([
                PluginSchemaGrant(grantee: .role("reporting"), privilege: "USAGE", grantor: "someone_else")
            ]),
            privileges: privileges
        )
        #expect(rows[0].holds("USAGE"))
        #expect(!rows[0].canEdit("USAGE"))
        /// An unheld privilege is always editable: a new grant needs no prior authority.
        #expect(rows[0].canEdit("CREATE"))
    }

    @Test("A privilege granted by two roles is not editable by either")
    func twoGrantorsMakeACellUneditable() {
        let rows = SchemaFormRules.rows(
            from: details([
                PluginSchemaGrant(grantee: .role("reporting"), privilege: "USAGE", grantor: "admin"),
                PluginSchemaGrant(grantee: .role("reporting"), privilege: "USAGE", grantor: "someone_else")
            ]),
            privileges: privileges
        )
        #expect(rows[0].holds("USAGE"))
        #expect(!rows[0].canEdit("USAGE"))
    }

    /// A privilege the engine does not declare cannot be rendered as a checkbox, so keeping it
    /// would let a Save drop it silently. It is dropped from the editor deliberately.
    @Test("A privilege outside the engine's catalog is not offered as a row")
    func ignoresUnknownPrivilege() {
        let rows = SchemaFormRules.rows(
            from: details([PluginSchemaGrant(grantee: .role("reporting"), privilege: "SELECT")]),
            privileges: privileges
        )
        #expect(rows.isEmpty)
    }

    @Test("Rows round-trip back to grants")
    func rowsRoundTrip() {
        let grants = [
            PluginSchemaGrant(grantee: .role("app_user"), privilege: "USAGE"),
            PluginSchemaGrant(grantee: .role("app_user"), privilege: "CREATE", isGrantable: true)
        ]
        let rows = SchemaFormRules.rows(from: details(grants), privileges: privileges)
        #expect(Set(SchemaFormRules.grants(from: rows)) == Set(grants))
    }

    /// The grantor is the server's and the editor never sets it, so comparing whole grants
    /// reported a change on every Save.
    @Test("A grant differing only by grantor is not a change")
    func grantorIsNotPartOfTheComparison() {
        let current = PluginSchemaDetails(
            name: "app_data",
            grants: [
                PluginSchemaGrant(grantee: .role("reporting"), privilege: "USAGE", grantor: "admin")
            ]
        )
        let target = PluginSchemaDefinition(
            name: "app_data",
            grants: [PluginSchemaGrant(grantee: .role("reporting"), privilege: "USAGE")]
        )
        #expect(!SchemaFormRules.hasChanges(from: current, to: target))
    }

    @Test("A schema identical to what is on the server has no changes to apply")
    func detectsNoChanges() {
        let current = PluginSchemaDetails(
            name: "app_data",
            owner: "app_user",
            comment: "Tables",
            grants: [PluginSchemaGrant(grantee: .role("reporting"), privilege: "USAGE")]
        )
        #expect(!SchemaFormRules.hasChanges(from: current, to: current.definition))
    }

    @Test("A changed owner, comment, name or grant each count as a change")
    func detectsEachChange() {
        let current = PluginSchemaDetails(name: "app_data", owner: "app_user", comment: "Tables")
        #expect(SchemaFormRules.hasChanges(
            from: current,
            to: PluginSchemaDefinition(name: "app_archive", owner: "app_user", comment: "Tables")
        ))
        #expect(SchemaFormRules.hasChanges(
            from: current,
            to: PluginSchemaDefinition(name: "app_data", owner: "other", comment: "Tables")
        ))
        #expect(SchemaFormRules.hasChanges(
            from: current,
            to: PluginSchemaDefinition(name: "app_data", owner: "app_user", comment: nil)
        ))
        #expect(SchemaFormRules.hasChanges(
            from: current,
            to: PluginSchemaDefinition(
                name: "app_data",
                owner: "app_user",
                comment: "Tables",
                grants: [PluginSchemaGrant(grantee: .role("reporting"), privilege: "USAGE")]
            )
        ))
    }

    /// An engine with no owner concept sends nil rather than an empty string, and nil means
    /// "leave it alone" rather than "clear it".
    @Test("An absent owner is not a change")
    func absentOwnerIsNotAChange() {
        let current = PluginSchemaDetails(name: "app_data", owner: "app_user")
        #expect(!SchemaFormRules.hasChanges(from: current, to: PluginSchemaDefinition(name: "app_data")))
    }
}
