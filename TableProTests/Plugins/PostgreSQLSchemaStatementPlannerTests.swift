//
//  PostgreSQLSchemaStatementPlannerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQL schema statement planner")
struct PostgreSQLSchemaStatementPlannerTests {
    @Test("A bare create names the schema and nothing else")
    func createWithoutOwner() {
        let statements = PostgreSQLSchemaStatementPlanner.create(
            PluginSchemaDefinition(name: "app_data")
        )
        #expect(statements == ["CREATE SCHEMA \"app_data\""])
    }

    @Test("An owner becomes an AUTHORIZATION clause on the create")
    func createWithOwner() {
        let statements = PostgreSQLSchemaStatementPlanner.create(
            PluginSchemaDefinition(name: "app_data", owner: "app_user")
        )
        #expect(statements == ["CREATE SCHEMA \"app_data\" AUTHORIZATION \"app_user\""])
    }

    @Test("A comment and grants follow the create, in that order")
    func createWithCommentAndGrants() {
        let statements = PostgreSQLSchemaStatementPlanner.create(
            PluginSchemaDefinition(
                name: "app_data",
                owner: "app_user",
                comment: "Application tables",
                grants: [
                    PluginSchemaGrant(grantee: "reporting", privilege: "USAGE"),
                    PluginSchemaGrant(grantee: "reporting", privilege: "CREATE")
                ]
            )
        )
        #expect(statements == [
            "CREATE SCHEMA \"app_data\" AUTHORIZATION \"app_user\"",
            "COMMENT ON SCHEMA \"app_data\" IS 'Application tables'",
            "GRANT CREATE, USAGE ON SCHEMA \"app_data\" TO \"reporting\""
        ])
    }

    @Test("A name with a double quote is quoted by doubling it, not by dropping it")
    func quotingSurvivesAnEmbeddedQuote() {
        let statements = PostgreSQLSchemaStatementPlanner.create(
            PluginSchemaDefinition(name: "my\"schema")
        )
        #expect(statements == ["CREATE SCHEMA \"my\"\"schema\""])
    }

    @Test("A name carrying a statement separator stays one identifier")
    func quotingContainsASeparator() {
        let statements = PostgreSQLSchemaStatementPlanner.create(
            PluginSchemaDefinition(name: "a; DROP SCHEMA public")
        )
        #expect(statements == ["CREATE SCHEMA \"a; DROP SCHEMA public\""])
    }

    @Test("PUBLIC is a keyword, so it is never quoted as a role name")
    func publicRoleIsNotQuoted() {
        let statements = PostgreSQLSchemaStatementPlanner.create(
            PluginSchemaDefinition(
                name: "app_data",
                grants: [PluginSchemaGrant(grantee: "PUBLIC", privilege: "USAGE")]
            )
        )
        #expect(statements == [
            "CREATE SCHEMA \"app_data\"",
            "GRANT USAGE ON SCHEMA \"app_data\" TO PUBLIC"
        ])
    }

    @Test("An unchanged schema produces no statements at all")
    func alterWithNoChanges() {
        let current = PluginSchemaDetails(
            name: "app_data",
            owner: "app_user",
            comment: "Application tables",
            grants: [PluginSchemaGrant(grantee: "reporting", privilege: "USAGE")]
        )
        #expect(PostgreSQLSchemaStatementPlanner.alter(from: current, to: current.definition).isEmpty)
    }

    @Test("A rename runs first and every later statement names the new schema")
    func renameComesFirstAndRetargets() {
        let current = PluginSchemaDetails(name: "app_data", owner: "app_user")
        let statements = PostgreSQLSchemaStatementPlanner.alter(
            from: current,
            to: PluginSchemaDefinition(name: "app_archive", owner: "another_role")
        )
        #expect(statements == [
            "ALTER SCHEMA \"app_data\" RENAME TO \"app_archive\"",
            "ALTER SCHEMA \"app_archive\" OWNER TO \"another_role\""
        ])
    }

    @Test("Clearing a comment writes NULL, because an empty string is a comment that exists")
    func clearingACommentWritesNull() {
        let current = PluginSchemaDetails(name: "app_data", comment: "old")
        let statements = PostgreSQLSchemaStatementPlanner.alter(
            from: current,
            to: PluginSchemaDefinition(name: "app_data")
        )
        #expect(statements == ["COMMENT ON SCHEMA \"app_data\" IS NULL"])
    }

    /// The pgAdmin #5926 defect: it emits a blanket REVOKE for grantees the user never touched.
    @Test("A grantee the user did not touch produces neither a GRANT nor a REVOKE")
    func untouchedGranteeEmitsNothing() {
        let current = PluginSchemaDetails(
            name: "app_data",
            grants: [
                PluginSchemaGrant(grantee: "untouched", privilege: "USAGE"),
                PluginSchemaGrant(grantee: "reporting", privilege: "USAGE")
            ]
        )
        let statements = PostgreSQLSchemaStatementPlanner.alter(
            from: current,
            to: PluginSchemaDefinition(
                name: "app_data",
                grants: [
                    PluginSchemaGrant(grantee: "untouched", privilege: "USAGE"),
                    PluginSchemaGrant(grantee: "reporting", privilege: "USAGE"),
                    PluginSchemaGrant(grantee: "reporting", privilege: "CREATE")
                ]
            )
        )
        #expect(statements == ["GRANT CREATE ON SCHEMA \"app_data\" TO \"reporting\""])
        #expect(!statements.contains { $0.contains("untouched") })
    }

    @Test("Clearing a privilege revokes only that one")
    func revokesOnlyTheClearedPrivilege() {
        let current = PluginSchemaDetails(
            name: "app_data",
            grants: [
                PluginSchemaGrant(grantee: "reporting", privilege: "USAGE"),
                PluginSchemaGrant(grantee: "reporting", privilege: "CREATE")
            ]
        )
        let statements = PostgreSQLSchemaStatementPlanner.alter(
            from: current,
            to: PluginSchemaDefinition(
                name: "app_data",
                grants: [PluginSchemaGrant(grantee: "reporting", privilege: "USAGE")]
            )
        )
        #expect(statements == ["REVOKE CREATE ON SCHEMA \"app_data\" FROM \"reporting\""])
    }

    @Test("Adding the grant option re-grants with it rather than revoking first")
    func addingTheGrantOption() {
        let current = PluginSchemaDetails(
            name: "app_data",
            grants: [PluginSchemaGrant(grantee: "reporting", privilege: "USAGE")]
        )
        let statements = PostgreSQLSchemaStatementPlanner.alter(
            from: current,
            to: PluginSchemaDefinition(
                name: "app_data",
                grants: [PluginSchemaGrant(grantee: "reporting", privilege: "USAGE", isGrantable: true)]
            )
        )
        #expect(statements == ["GRANT USAGE ON SCHEMA \"app_data\" TO \"reporting\" WITH GRANT OPTION"])
    }

    /// A plain REVOKE would take the privilege away with the option, which is not what clearing
    /// the grant-option box asks for.
    @Test("Dropping the grant option keeps the privilege")
    func droppingTheGrantOptionKeepsThePrivilege() {
        let current = PluginSchemaDetails(
            name: "app_data",
            grants: [PluginSchemaGrant(grantee: "reporting", privilege: "USAGE", isGrantable: true)]
        )
        let statements = PostgreSQLSchemaStatementPlanner.alter(
            from: current,
            to: PluginSchemaDefinition(
                name: "app_data",
                grants: [PluginSchemaGrant(grantee: "reporting", privilege: "USAGE")]
            )
        )
        #expect(statements == [
            "GRANT USAGE ON SCHEMA \"app_data\" TO \"reporting\"",
            "REVOKE GRANT OPTION FOR USAGE ON SCHEMA \"app_data\" FROM \"reporting\""
        ])
    }

    /// The re-read is only worth doing if the untouched facets come from it. Passing the whole
    /// form back reverted whatever another session had changed, which is the blanket-revoke defect
    /// this design exists to avoid.
    @Test("A concurrent grant on an untouched role survives an edit to another facet")
    func concurrentGrantSurvivesACommentEdit() {
        let latest = PluginSchemaDetails(
            name: "app_data",
            comment: "old",
            grants: [PluginSchemaGrant(grantee: "added_elsewhere", privilege: "USAGE")]
        )
        let statements = PostgreSQLSchemaStatementPlanner.alter(
            from: latest,
            to: PluginSchemaDefinition(
                name: "app_data",
                comment: "new",
                grants: latest.grants
            )
        )
        #expect(statements == ["COMMENT ON SCHEMA \"app_data\" IS 'new'"])
    }

    /// A nil owner means "leave it alone". Sending an empty string instead would be read as a
    /// change and emit an `ALTER SCHEMA … OWNER TO ""`.
    @Test("An absent owner emits no owner statement")
    func absentOwnerEmitsNothing() {
        let latest = PluginSchemaDetails(name: "app_data", owner: "app_user")
        let statements = PostgreSQLSchemaStatementPlanner.alter(
            from: latest,
            to: PluginSchemaDefinition(name: "app_data", owner: nil)
        )
        #expect(statements.isEmpty)
    }

    @Test("A privilege name the sanitizer rejects never reaches a statement")
    func rejectsAnInjectedPrivilegeName() {
        let statements = PostgreSQLSchemaStatementPlanner.create(
            PluginSchemaDefinition(
                name: "app_data",
                grants: [PluginSchemaGrant(grantee: "reporting", privilege: "USAGE; DROP SCHEMA public")]
            )
        )
        #expect(statements == ["CREATE SCHEMA \"app_data\""])
    }
}
