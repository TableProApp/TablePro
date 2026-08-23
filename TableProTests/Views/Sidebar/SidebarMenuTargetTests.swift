//
//  SidebarMenuTargetTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Sidebar Menu Target")
struct SidebarMenuTargetTests {
    @Test("Clicking inside the selection acts on the whole selection")
    func clickInsideSelectionActsOnSelection() {
        let target = SidebarMenuTarget.resolve(clicked: "b", selection: ["a", "b", "c"])
        #expect(target == ["a", "b", "c"])
    }

    @Test("Clicking outside the selection acts on the clicked row only")
    func clickOutsideSelectionActsOnClickedRow() {
        let target = SidebarMenuTarget.resolve(clicked: "d", selection: ["a", "b", "c"])
        #expect(target == ["d"])
    }

    @Test("An empty selection acts on the clicked row")
    func emptySelectionActsOnClickedRow() {
        let target = SidebarMenuTarget.resolve(clicked: "a", selection: [String]())
        #expect(target == ["a"])
    }

    @Test("No clicked row falls back to the selection")
    func noClickedRowUsesSelection() {
        let target = SidebarMenuTarget.resolve(clicked: String?.none, selection: ["a", "b"])
        #expect(target == ["a", "b"])
    }

    @Test("A mixed selection is filtered to the clicked row's kind")
    func mixedSelectionFiltersByKind() {
        let clicked = DatabaseContainerRef.database("sales")
        let selection: [DatabaseContainerRef] = [
            .database("sales"),
            .database("analytics"),
            .schema(database: "sales", schema: "public")
        ]

        let target = SidebarMenuTarget.resolveContainers(clicked: clicked, selection: selection)

        #expect(target.map(\.name) == ["analytics", "sales"])
        #expect(target.allSatisfy { $0.kind == .database })
    }

    @Test("Clicking a schema outside the selection drops the selected databases")
    func schemaClickOutsideSelectionActsAlone() {
        let clicked = DatabaseContainerRef.schema(database: "sales", schema: "reporting")
        let selection: [DatabaseContainerRef] = [.database("sales"), .database("analytics")]

        let target = SidebarMenuTarget.resolveContainers(clicked: clicked, selection: selection)

        #expect(target == [clicked])
    }

    @Test("The same schema name under two databases stays distinct")
    func sameSchemaNameDifferentDatabaseIsDistinct() {
        let first = DatabaseContainerRef.schema(database: "db1", schema: "public")
        let second = DatabaseContainerRef.schema(database: "db2", schema: "public")

        #expect(first != second)
        #expect(Set([first, second]).count == 2)
    }
}
