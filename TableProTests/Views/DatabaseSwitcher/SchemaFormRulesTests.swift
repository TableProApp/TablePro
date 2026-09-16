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

    @Test("Grants become one row per grantee, sorted, with the grant option kept")
    func buildsRows() {
        let rows = SchemaFormRules.rows(
            from: [
                PluginSchemaGrant(grantee: "reporting", privilege: "USAGE"),
                PluginSchemaGrant(grantee: "app_user", privilege: "CREATE", isGrantable: true),
                PluginSchemaGrant(grantee: "app_user", privilege: "USAGE")
            ],
            privileges: privileges
        )
        #expect(rows.map(\.grantee) == ["app_user", "reporting"])
        #expect(rows[0].granted == ["USAGE", "CREATE"])
        #expect(rows[0].grantable == ["CREATE"])
        #expect(rows[1].granted == ["USAGE"])
    }

    /// A privilege the engine does not declare cannot be rendered as a checkbox, so keeping it
    /// would let a Save drop it silently. It is dropped from the editor deliberately.
    @Test("A privilege outside the engine's catalog is not offered as a row")
    func ignoresUnknownPrivilege() {
        let rows = SchemaFormRules.rows(
            from: [PluginSchemaGrant(grantee: "reporting", privilege: "SELECT")],
            privileges: privileges
        )
        #expect(rows.isEmpty)
    }

    @Test("Rows round-trip back to grants")
    func rowsRoundTrip() {
        let grants = [
            PluginSchemaGrant(grantee: "app_user", privilege: "USAGE"),
            PluginSchemaGrant(grantee: "app_user", privilege: "CREATE", isGrantable: true)
        ]
        let rows = SchemaFormRules.rows(from: grants, privileges: privileges)
        #expect(Set(SchemaFormRules.grants(from: rows)) == Set(grants))
    }

    @Test("A schema identical to what is on the server has no changes to apply")
    func detectsNoChanges() {
        let current = PluginSchemaDetails(
            name: "app_data",
            owner: "app_user",
            comment: "Tables",
            grants: [PluginSchemaGrant(grantee: "reporting", privilege: "USAGE")]
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
                grants: [PluginSchemaGrant(grantee: "reporting", privilege: "USAGE")]
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
