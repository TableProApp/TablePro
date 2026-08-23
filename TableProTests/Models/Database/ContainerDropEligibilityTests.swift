//
//  ContainerDropEligibilityTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Container Drop Eligibility")
struct ContainerDropEligibilityTests {
    private func context(
        activeDatabase: String? = "sales",
        activeSchema: String? = "public",
        supportsDropDatabase: Bool = true,
        supportsDropSchema: Bool = true,
        isReadOnly: Bool = false
    ) -> ContainerDropEligibility.Context {
        ContainerDropEligibility.Context(
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            supportsDropDatabase: supportsDropDatabase,
            supportsDropSchema: supportsDropSchema,
            isReadOnly: isReadOnly
        )
    }

    @Test("System databases are never droppable")
    func systemDatabaseExcluded() {
        let targets: [DatabaseContainerRef] = [
            .database("mysql", isSystem: true),
            .database("analytics")
        ]

        let droppable = ContainerDropEligibility.droppable(targets, context: context())

        #expect(droppable.map(\.name) == ["analytics"])
    }

    @Test("The active database is not droppable")
    func activeDatabaseExcluded() {
        let targets: [DatabaseContainerRef] = [.database("sales"), .database("analytics")]

        let droppable = ContainerDropEligibility.droppable(targets, context: context())

        #expect(droppable.map(\.name) == ["analytics"])
    }

    @Test("The active schema of the active database is not droppable")
    func activeSchemaExcluded() {
        let targets: [DatabaseContainerRef] = [
            .schema(database: "sales", schema: "public"),
            .schema(database: "sales", schema: "reporting")
        ]

        let droppable = ContainerDropEligibility.droppable(targets, context: context())

        #expect(droppable.map(\.name) == ["reporting"])
    }

    @Test("A schema named like the active one in another database stays droppable")
    func sameSchemaNameInOtherDatabaseAllowed() {
        let targets: [DatabaseContainerRef] = [.schema(database: "analytics", schema: "public")]

        let droppable = ContainerDropEligibility.droppable(targets, context: context())

        #expect(droppable.count == 1)
    }

    @Test("System schemas are never droppable")
    func systemSchemaExcluded() {
        let targets: [DatabaseContainerRef] = [
            .schema(database: "sales", schema: "pg_catalog", isSystem: true)
        ]

        #expect(ContainerDropEligibility.droppable(targets, context: context()).isEmpty)
    }

    @Test("Drivers without the capability drop nothing")
    func capabilityGatesEachKind() {
        let databases: [DatabaseContainerRef] = [.database("analytics")]
        let schemas: [DatabaseContainerRef] = [.schema(database: "analytics", schema: "reporting")]

        #expect(
            ContainerDropEligibility.droppable(
                databases, context: context(supportsDropDatabase: false)
            ).isEmpty
        )
        #expect(
            ContainerDropEligibility.droppable(
                schemas, context: context(supportsDropSchema: false)
            ).isEmpty
        )
    }

    @Test("Read-only connections drop nothing")
    func readOnlyDropsNothing() {
        let targets: [DatabaseContainerRef] = [.database("analytics")]

        #expect(ContainerDropEligibility.droppable(targets, context: context(isReadOnly: true)).isEmpty)
    }

    // MARK: - Engines that browse no database

    /// `database` is optional now, so nil has to compare equal to nil here. No producer feeds a
    /// nil database in today, which is the only reason the string form never mismatched its way
    /// into offering the schema in use for dropping, the way the sidebar's own comparison did.
    @Test("The active schema is not droppable when the engine browses no database")
    func activeSchemaExcludedWithoutADatabase() {
        let targets: [DatabaseContainerRef] = [
            .schema(database: nil, schema: "SYSDBA"),
            .schema(database: nil, schema: "REPORTING")
        ]

        let droppable = ContainerDropEligibility.droppable(
            targets, context: context(activeDatabase: nil, activeSchema: "SYSDBA")
        )

        #expect(droppable.map(\.name) == ["REPORTING"])
    }
}
