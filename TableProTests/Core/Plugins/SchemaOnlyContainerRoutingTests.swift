//
//  SchemaOnlyContainerRoutingTests.swift
//  TableProTests
//
//  An engine that browses no database must never be asked to switch one. Composing the declared
//  capabilities with the planner is the whole decision, so these pin both halves together: the
//  values each engine declares, and the plan they produce for a sidebar click (#2262).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("Schema-only container routing")
struct SchemaOnlyContainerRoutingTests {
    private func switchable(_ type: DatabaseType) -> [ContainerSwitchTarget] {
        PluginManager.shared.switchableContainers(for: type)
    }

    /// The click the reporter made: a table inside a schema, on a connection that browses no
    /// database, so the tree hands over a nil database. Planning a database step here reached the
    /// driver, which has no database to switch to, and its refusal became a modal alert.
    private func planForTableClick(_ type: DatabaseType, schema: String?) -> [ContainerSwitchStep] {
        ContainerSwitchPlanner.plan(database: nil, schema: schema, switchable: switchable(type))
    }

    // MARK: - What each engine declares

    @Test("Schema-only engines declare the schema dimension and no database dimension")
    func schemaOnlyEnginesDeclareOnlySchema() {
        for type in [DatabaseType.dameng, .oracle, .bigQuery] {
            #expect(switchable(type) == [.schema], "\(type.rawValue)")
            #expect(PluginManager.shared.containerSwitchTarget(for: type) == .schema, "\(type.rawValue)")
        }
    }

    /// Redis switches a numbered database while declaring neither dimension, so a rule keyed on
    /// `supportsDatabaseSwitching` would have taken its database switching away.
    @Test("Redis declares no switchable dimension at all")
    func redisDeclaresNoDimension() {
        #expect(switchable(.redis).isEmpty)
        #expect(PluginManager.shared.containerSwitchTarget(for: .redis) == nil)
    }

    @Test("Engines with both dimensions still declare both, outermost first")
    func dualDimensionEnginesDeclareBoth() {
        for type in [DatabaseType.postgresql, .mssql] {
            #expect(switchable(type) == [.database, .schema], "\(type.rawValue)")
            #expect(PluginManager.shared.containerSwitchTarget(for: type) == .database, "\(type.rawValue)")
        }
    }

    // MARK: - The plan a sidebar click produces

    @Test("Clicking a table on a schema-only engine plans only the schema")
    func tableClickOnSchemaOnlyEnginePlansOnlyTheSchema() {
        for type in [DatabaseType.dameng, .oracle, .bigQuery] {
            #expect(planForTableClick(type, schema: "REPORTING") == [.schema("REPORTING")], "\(type.rawValue)")
        }
    }

    /// Elasticsearch and etcd render no Database field at all, so every connection browses none
    /// and every index or key click arrived here with both segments empty. This planned a switch
    /// to a database named nothing, which is what produced the alert on every click.
    @Test("Clicking an object on an engine with no containers at all plans nothing")
    func objectClickOnContainerlessEnginePlansNothing() {
        for type in [DatabaseType.elasticsearch, .etcd] {
            #expect(planForTableClick(type, schema: nil).isEmpty, "\(type.rawValue)")
        }
    }

    /// The guarantee the fix must not break: an engine that really does have databases still
    /// gets its database step, and still gets it before the schema.
    @Test("Clicking a table on a dual-dimension engine still switches both, database first")
    func dualDimensionEngineStillSwitchesBoth() {
        let steps = ContainerSwitchPlanner.plan(
            database: "app",
            schema: "reporting",
            switchable: switchable(.postgresql)
        )

        #expect(steps == [.database("app"), .schema("reporting")])
    }
}
