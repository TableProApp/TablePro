//
//  ConnectionScopeTests.swift
//  TableProTests
//
//  Tests for the toolbar's scope components: one per container dimension the engine switches.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("ConnectionScopeResolver")
struct ConnectionScopeTests {
    private func components(
        switchable: [ContainerSwitchTarget],
        grouping: GroupingStrategy = .bySchema,
        database: String = "app",
        schema: String? = "public"
    ) -> [ConnectionScopeComponent] {
        ConnectionScopeResolver.components(
            switchable: switchable,
            groupingStrategy: grouping,
            currentDatabase: database,
            currentSchema: schema,
            containerEntityName: "Database",
            schemaEntityName: "Schema"
        )
    }

    // MARK: - Dual-dimension engines

    @Test("An engine that switches both dimensions gets a component for each, outermost first")
    func dualModeGetsBothComponents() {
        let resolved = components(switchable: [.database, .schema])

        #expect(resolved.count == 2)
        #expect(resolved[0].kind == .database)
        #expect(resolved[0].name == "app")
        #expect(resolved[0].label == "Database")
        #expect(resolved[1].kind == .schema)
        #expect(resolved[1].name == "public")
        #expect(resolved[1].label == "Schema")
    }

    /// The defect in #2196: the chip displayed the schema while its click opened the database list.
    /// A component's name and its chooser both come from `kind`, so they cannot describe different
    /// scopes any more.
    @Test("Every component names the scope its own chooser switches")
    func componentKindMatchesItsName() {
        let resolved = components(switchable: [.database, .schema], database: "analytics", schema: "reporting")

        for component in resolved {
            switch component.kind {
            case .database:
                #expect(component.name == "analytics")
                #expect(component.label == "Database")
            case .schema:
                #expect(component.name == "reporting")
                #expect(component.label == "Schema")
            }
        }
    }

    @Test("A dual-dimension engine grouped hierarchically also gets both components")
    func hierarchicalDualModeGetsBothComponents() {
        let resolved = components(switchable: [.database, .schema], grouping: .hierarchicalSchema)

        #expect(resolved.map(\.kind) == [.database, .schema])
    }

    @Test("Both components are switchable")
    func dualModeComponentsAreSwitchable() {
        let switchableFlags = components(switchable: [.database, .schema]).map(\.isSwitchable)

        #expect(switchableFlags == [true, true])
    }

    // MARK: - Single-dimension engines

    @Test("A database-only engine gets one database component")
    func databaseOnlyEngine() {
        let resolved = components(switchable: [.database], grouping: .byDatabase, schema: nil)

        #expect(resolved.count == 1)
        #expect(resolved[0].kind == .database)
        #expect(resolved[0].name == "app")
    }

    @Test("A schema-only engine gets one schema component")
    func schemaOnlyEngine() {
        let resolved = components(switchable: [.schema], grouping: .hierarchicalSchema, schema: "HR")

        #expect(resolved.count == 1)
        #expect(resolved[0].kind == .schema)
        #expect(resolved[0].name == "HR")
    }

    // MARK: - Engines that switch nothing

    @Test("An engine that switches nothing still shows what it is browsing, unswitchable")
    func nonSwitchingEngineKeepsAStaticComponent() {
        let resolved = components(switchable: [], grouping: .flat, database: "chinook.db", schema: nil)

        #expect(resolved.count == 1)
        #expect(resolved[0].kind == .database)
        #expect(resolved[0].name == "chinook.db")
        #expect(resolved[0].isSwitchable == false)
    }

    @Test("A non-switching schema-grouped engine shows its resolved schema")
    func nonSwitchingSchemaGroupedEngineShowsSchema() {
        let resolved = components(switchable: [], grouping: .bySchema, database: "sales", schema: "dbo")

        #expect(resolved.count == 1)
        #expect(resolved[0].kind == .schema)
        #expect(resolved[0].name == "dbo")
        #expect(resolved[0].isSwitchable == false)
    }

    // MARK: - Unresolved values

    @Test("A dimension with no value yet is dropped rather than shown blank")
    func unresolvedSchemaIsDropped() {
        let resolved = components(switchable: [.database, .schema], schema: nil)

        #expect(resolved.map(\.kind) == [.database])
    }

    @Test("An empty schema name is dropped the same way a missing one is")
    func emptySchemaIsDropped() {
        let resolved = components(switchable: [.database, .schema], schema: "")

        #expect(resolved.map(\.kind) == [.database])
    }

    @Test("A connection with nothing resolved yet shows no components")
    func nothingResolvedShowsNothing() {
        let resolved = components(switchable: [.database, .schema], database: "", schema: nil)

        #expect(resolved.isEmpty)
    }

    /// A schema-only engine has no database component to fall back on, so dropping the unresolved
    /// schema would empty the toolbar between connecting and the schema arriving.
    @Test("A schema-only engine falls back to its database until the schema resolves")
    func schemaOnlyEngineFallsBackWhileUnresolved() {
        let resolved = components(
            switchable: [.schema], grouping: .hierarchicalSchema, database: "ORCL", schema: nil
        )

        #expect(resolved.count == 1)
        #expect(resolved[0].kind == .database)
        #expect(resolved[0].name == "ORCL")
        #expect(resolved[0].isSwitchable == false)
    }

    @Test("The fallback disappears once the schema resolves")
    func schemaOnlyEngineShowsItsSchemaOnceResolved() {
        let resolved = components(
            switchable: [.schema], grouping: .hierarchicalSchema, database: "ORCL", schema: "HR"
        )

        #expect(resolved.map(\.kind) == [.schema])
        #expect(resolved[0].name == "HR")
        #expect(resolved[0].isSwitchable)
    }

    @Test("A driver's own words are used for each label")
    func labelsFollowTheDriverVocabulary() {
        let resolved = ConnectionScopeResolver.components(
            switchable: [.database, .schema],
            groupingStrategy: .hierarchicalSchema,
            currentDatabase: "warehouse",
            currentSchema: "analytics",
            containerEntityName: "Catalog",
            schemaEntityName: "Dataset"
        )

        #expect(resolved.map(\.label) == ["Catalog", "Dataset"])
    }
}

@MainActor
@Suite("Container switch targets")
struct ContainerSwitchTargetResolutionTests {
    /// Every type the app's own registry declares as browsing a database and a schema within it.
    /// All of them lost the schema control when the single-target enum answered `.database` for
    /// the lot (#2196).
    @Test(
        "Dual-dimension engines expose both containers",
        arguments: [
            DatabaseType.postgresql,
            .redshift,
            .cockroachdb,
            .pglite,
            .mssql,
            .duckdb,
            DatabaseType(rawValue: "Snowflake"),
            DatabaseType(rawValue: "Trino"),
        ]
    )
    func dualModeEnginesExposeBothContainers(_ type: DatabaseType) {
        #expect(PluginManager.shared.switchableContainers(for: type) == [.database, .schema])
    }

    /// Anchoring keeps the outermost dimension, so tab binding, the workspace rail and the bulk
    /// close commands behave exactly as they did.
    @Test("The anchoring target stays the outermost container")
    func anchoringTargetIsTheOutermostContainer() {
        #expect(PluginManager.shared.containerSwitchTarget(for: .postgresql) == .database)
        #expect(PluginManager.shared.containerSwitchTarget(for: .mysql) == .database)
    }

    @Test("A schema-only engine exposes only its schema")
    func schemaOnlyEngineExposesOnlySchema() {
        #expect(PluginManager.shared.switchableContainers(for: .oracle) == [.schema])
        #expect(PluginManager.shared.containerSwitchTarget(for: .oracle) == .schema)
    }

    @Test("An engine that switches nothing exposes nothing")
    func nonSwitchingEngineExposesNothing() {
        #expect(PluginManager.shared.switchableContainers(for: .redis).isEmpty)
        #expect(PluginManager.shared.containerSwitchTarget(for: .redis) == nil)
    }
}
