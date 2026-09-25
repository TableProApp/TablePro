//
//  DatabaseDropRequestTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct DatabaseDropRequestTests {
    private func request(
        _ targets: [DatabaseContainerRef],
        entityName: String = "Database",
        entityNamePlural: String = "Databases",
        dropsDependentObjects: Bool = false
    ) -> DatabaseDropRequest {
        DatabaseDropRequest(
            targets: targets,
            entityName: entityName,
            entityNamePlural: entityNamePlural,
            dropsDependentObjects: dropsDependentObjects
        )
    }

    @Test("A single target names the container in the title")
    func singleTargetTitle() {
        let dropRequest = request([.database("sales")])

        #expect(dropRequest.title.contains("sales"))
        #expect(dropRequest.title.contains("database"))
        #expect(!dropRequest.message.contains("sales"))
    }

    @Test("Several targets count in the title and list every name")
    func multipleTargetTitleAndMessage() {
        let dropRequest = request([.database("sales"), .database("analytics"), .database("archive")])

        #expect(dropRequest.title.contains("3"))
        #expect(dropRequest.title.contains("databases"))
        for name in ["sales", "analytics", "archive"] {
            #expect(dropRequest.message.contains(name))
        }
    }

    @Test("Targets are sorted by name")
    func targetsSorted() {
        let dropRequest = request([.database("sales"), .database("analytics")])

        #expect(dropRequest.names == ["analytics", "sales"])
    }

    @Test("A long list is capped and reports the overflow")
    func longListIsCapped() {
        let targets = (1...14).map { DatabaseContainerRef.database("db\($0)") }

        let dropRequest = request(targets)

        #expect(dropRequest.message.contains("and 4 more"))
        #expect(dropRequest.message.contains("db10"))
        #expect(!dropRequest.message.contains("db11"))
    }

    @Test("Schema drops warn about dependent objects")
    func schemaDropWarnsAboutDependents() {
        let dropRequest = request(
            [.schema(database: "sales", schema: "reporting")],
            entityName: "Schema",
            entityNamePlural: "Schemas",
            dropsDependentObjects: true
        )

        #expect(dropRequest.kind == .schema)
        #expect(dropRequest.message.contains("depend"))
    }

    /// SQL Server and BigQuery have no `CASCADE` and refuse a non-empty schema outright, so the
    /// confirmation must not promise to take dependent objects with it. The same sentence used to
    /// appear for every engine, which made it both an understatement on PostgreSQL and a promise
    /// SQL Server could not keep.
    @Test("A schema drop on an engine with no cascade promises nothing about dependents")
    func schemaDropWithoutCascadeMakesNoPromise() {
        let dropRequest = request(
            [.schema(database: "sales", schema: "reporting")],
            entityName: "Schema",
            entityNamePlural: "Schemas",
            dropsDependentObjects: false
        )

        #expect(dropRequest.kind == .schema)
        #expect(!dropRequest.message.contains("depend"))
    }

    @Test("The menu title ends with an ellipsis because it opens a confirmation")
    func menuTitleHasEllipsis() {
        #expect(request([.database("sales")]).menuTitle.hasSuffix("…"))
        #expect(request([.database("a"), .database("b")]).menuTitle.hasSuffix("…"))
    }

    @Test("Identity follows the target set")
    func identityFollowsTargets() {
        let first = request([.database("a"), .database("b")])
        let second = request([.database("b"), .database("a")])
        let third = request([.database("a")])

        #expect(first.id == second.id)
        #expect(first.id != third.id)
    }
}
