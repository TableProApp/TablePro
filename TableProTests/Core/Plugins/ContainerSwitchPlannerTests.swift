//
//  ContainerSwitchPlannerTests.swift
//  TableProTests
//
//  A link names dimensions, not one container. These pin which switches each engine shape gets.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Container switch planner")
struct ContainerSwitchPlannerTests {
    // MARK: - Engines with both dimensions

    /// The reported defect: the database segment was applied as a schema switch, because the
    /// router chose one dimension by asking only whether the engine had schemas at all.
    @Test("A database-only link on a dual-dimension engine switches the database")
    func databaseOnlyLinkSwitchesTheDatabase() {
        let steps = ContainerSwitchPlanner.plan(
            database: "analytics", schema: nil, switchable: [.database, .schema]
        )

        #expect(steps == [.database("analytics")])
    }

    @Test("A link naming both applies the database first and the schema second")
    func bothSegmentsApplyOutermostFirst() {
        let steps = ContainerSwitchPlanner.plan(
            database: "app", schema: "reporting", switchable: [.database, .schema]
        )

        #expect(steps == [.database("app"), .schema("reporting")])
    }

    @Test("A schema-only link on a dual-dimension engine switches only the schema")
    func schemaOnlyLinkSwitchesOnlyTheSchema() {
        let steps = ContainerSwitchPlanner.plan(
            database: nil, schema: "reporting", switchable: [.database, .schema]
        )

        #expect(steps == [.schema("reporting")])
    }

    // MARK: - Single-dimension engines

    @Test("A database-only engine ignores a schema segment it cannot apply")
    func databaseOnlyEngineDropsTheSchema() {
        let steps = ContainerSwitchPlanner.plan(
            database: "app", schema: "reporting", switchable: [.database]
        )

        #expect(steps == [.database("app")])
    }

    /// The mirror of the reported defect: a dimension the engine lacks is dropped, never rerouted
    /// onto the one it has. A schema name must not become a database switch either.
    @Test("A database-only engine given only a schema plans nothing")
    func databaseOnlyEngineGivenOnlyASchemaPlansNothing() {
        let steps = ContainerSwitchPlanner.plan(
            database: nil, schema: "reporting", switchable: [.database]
        )

        #expect(steps.isEmpty)
    }

    /// Oracle, Dameng and BigQuery have no database dimension, so a link that names only a
    /// database is naming what those engines call a schema. That is the one reroute worth keeping.
    @Test("A schema-only engine reads a lone database segment as its schema")
    func schemaOnlyEngineReadsDatabaseSegmentAsSchema() {
        let steps = ContainerSwitchPlanner.plan(
            database: "HR", schema: nil, switchable: [.schema]
        )

        #expect(steps == [.schema("HR")])
    }

    @Test("A schema-only engine prefers an explicit schema segment over the database segment")
    func schemaOnlyEnginePrefersTheExplicitSchema() {
        let steps = ContainerSwitchPlanner.plan(
            database: "ORCL", schema: "HR", switchable: [.schema]
        )

        #expect(steps == [.schema("HR")])
    }

    // MARK: - Engines that declare nothing

    /// Redis browses a numbered database and declares neither dimension. Dropping the segment
    /// because the engine reports nothing switchable would break links that work today.
    @Test("An engine that declares no switchable container still tries the database")
    func engineWithoutDeclaredContainersStillSwitchesDatabase() {
        let steps = ContainerSwitchPlanner.plan(database: "3", schema: nil, switchable: [])

        #expect(steps == [.database("3")])
    }

    @Test("An engine that declares no switchable container drops a schema segment")
    func engineWithoutDeclaredContainersDropsSchema() {
        let steps = ContainerSwitchPlanner.plan(database: nil, schema: "public", switchable: [])

        #expect(steps.isEmpty)
    }

    // MARK: - Nothing to do

    @Test("A link that names no container plans nothing")
    func emptyLinkPlansNothing() {
        #expect(ContainerSwitchPlanner.plan(
            database: nil, schema: nil, switchable: [.database, .schema]
        ).isEmpty)
    }

    @Test("Empty names are ignored rather than switched to")
    func emptyNamesAreIgnored() {
        let steps = ContainerSwitchPlanner.plan(
            database: "", schema: "", switchable: [.database, .schema]
        )

        #expect(steps.isEmpty)
    }
}
