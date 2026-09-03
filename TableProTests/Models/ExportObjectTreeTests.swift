//
//  ExportObjectTreeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Export object kinds")
struct ExportObjectKindTests {

    @Test("Dump order creates every dependency before the thing that needs it")
    func dumpOrderRespectsDependencies() {
        #expect(PluginExportObjectKind.userType.dumpOrder < PluginExportObjectKind.table.dumpOrder)
        #expect(PluginExportObjectKind.sequence.dumpOrder < PluginExportObjectKind.table.dumpOrder)
        #expect(PluginExportObjectKind.table.dumpOrder < PluginExportObjectKind.view.dumpOrder)
        #expect(PluginExportObjectKind.view.dumpOrder < PluginExportObjectKind.routine.dumpOrder)
        #expect(PluginExportObjectKind.routine.dumpOrder < PluginExportObjectKind.trigger.dumpOrder)
        #expect(PluginExportObjectKind.trigger.dumpOrder < PluginExportObjectKind.grant.dumpOrder)
    }

    @Test("Grants sort last, because every object they name has to exist first")
    func grantsSortLast() {
        let maxOther = PluginExportObjectKind.allCases
            .filter { $0 != .grant }
            .map(\.dumpOrder)
            .max() ?? 0
        #expect(PluginExportObjectKind.grant.dumpOrder > maxOther)
    }

    @Test("Only tables and foreign tables carry rows")
    func onlyTablesCarryRows() {
        let rowCarrying = PluginExportObjectKind.allCases.filter(\.carriesRows)
        #expect(Set(rowCarrying) == Set([.table, .foreignTable]))
    }

    @Test("Table type strings map to the right kind")
    func tableTypeMapping() {
        #expect(PluginExportObjectKind.from(tableType: "BASE TABLE") == .table)
        #expect(PluginExportObjectKind.from(tableType: "VIEW") == .view)
        #expect(PluginExportObjectKind.from(tableType: "MATERIALIZED VIEW") == .materializedView)
        #expect(PluginExportObjectKind.from(tableType: "FOREIGN TABLE") == .foreignTable)
        #expect(PluginExportObjectKind.from(tableType: "table") == .table)
    }

    /// A materialized view names both "materialized" and "view", so the order the cases are tested
    /// in is what keeps it out of the plain view arm.
    @Test("Materialized view wins over the plain view match")
    func materializedViewBeatsView() {
        #expect(PluginExportObjectKind.from(tableType: "SYSTEM MATERIALIZED VIEW") == .materializedView)
    }

    @Test("A format that declares no kinds receives only tables and views")
    func legacyDefaultIsTablesAndViews() {
        #expect(Set(PluginExportObjectKind.legacyDefault) == Set([.table, .view]))
    }

    @Test("Every kind but grant has a drop keyword")
    func dropKeywordsPresent() {
        for kind in PluginExportObjectKind.allCases where kind != .grant {
            #expect(!kind.dropKeyword.isEmpty, "\(kind) has no drop keyword")
        }
        #expect(PluginExportObjectKind.grant.dropKeyword.isEmpty)
    }
}

@Suite("Export outline tree")
struct ExportOutlineTreeTests {

    private func database(named name: String, objects: [ExportObjectItem]) -> ExportDatabaseItem {
        ExportDatabaseItem(name: name, objects: objects)
    }

    @Test("A database holding one kind skips the group level")
    func singleKindSkipsGroups() {
        let item = database(named: "app", objects: [
            ExportObjectItem(name: "users", kind: .table),
            ExportObjectItem(name: "posts", kind: .table)
        ])
        let roots = ExportOutlineTreeBuilder.build(from: [item])
        #expect(roots.count == 1)
        #expect(roots[0].children.count == 2)
        for child in roots[0].children {
            guard case .object = child.kind else {
                Issue.record("expected an object row directly under the database")
                return
            }
        }
    }

    @Test("A database holding several kinds groups them in dump order")
    func multipleKindsGroupInDumpOrder() {
        let item = database(named: "app", objects: [
            ExportObjectItem(name: "audit", kind: .trigger, parentTable: "users"),
            ExportObjectItem(name: "users", kind: .table),
            ExportObjectItem(name: "active_users", kind: .view),
            ExportObjectItem(name: "status", kind: .userType)
        ])
        let roots = ExportOutlineTreeBuilder.build(from: [item])
        let kinds = roots[0].children.compactMap { node -> PluginExportObjectKind? in
            guard case .group(_, let kind) = node.kind else { return nil }
            return kind
        }
        #expect(kinds == [.userType, .table, .view, .trigger])
    }

    @Test("Each group holds only its own kind")
    func groupsHoldTheirOwnKind() {
        let item = database(named: "app", objects: [
            ExportObjectItem(name: "users", kind: .table),
            ExportObjectItem(name: "posts", kind: .table),
            ExportObjectItem(name: "active_users", kind: .view)
        ])
        let roots = ExportOutlineTreeBuilder.build(from: [item])
        let tableGroup = roots[0].children.first { node in
            guard case .group(_, let kind) = node.kind else { return false }
            return kind == .table
        }
        #expect(tableGroup?.children.count == 2)
    }

    @Test("Node identity is stable and distinguishes a kind group from its database")
    func nodeIdentityIsStable() {
        let item = database(named: "app", objects: [
            ExportObjectItem(name: "users", kind: .table),
            ExportObjectItem(name: "active_users", kind: .view)
        ])
        let first = ExportOutlineTreeBuilder.build(from: [item])
        let second = ExportOutlineTreeBuilder.build(from: [item])
        #expect(first[0].identity == second[0].identity)
        #expect(first[0].identity != first[0].children[0].identity)
        #expect(first[0].children[0].identity != first[0].children[1].identity)
    }

    /// The tree is only rebuilt when its shape changes, so a checkbox must not move the
    /// fingerprint: rebuilding on every toggle collapses the group under the user's pointer.
    @Test("Toggling a checkbox leaves the shape fingerprint unchanged")
    func selectionDoesNotChangeShape() {
        var item = database(named: "app", objects: [
            ExportObjectItem(name: "users", kind: .table),
            ExportObjectItem(name: "active_users", kind: .view)
        ])
        let before = ExportOutlineTreeBuilder.shapeFingerprint(of: [item])
        item.objects[0].isSelected = true
        item.objects[1].optionValues = [true, false, true]
        item.objects[0].rowScope = PluginExportRowScope(filter: "id > 5")
        let after = ExportOutlineTreeBuilder.shapeFingerprint(of: [item])
        #expect(before == after)
    }

    @Test("Adding an object changes the shape fingerprint")
    func addingAnObjectChangesShape() {
        var item = database(named: "app", objects: [ExportObjectItem(name: "users", kind: .table)])
        let before = ExportOutlineTreeBuilder.shapeFingerprint(of: [item])
        item.objects.append(ExportObjectItem(name: "posts", kind: .table))
        let after = ExportOutlineTreeBuilder.shapeFingerprint(of: [item])
        #expect(before != after)
    }

    @Test("Present kinds come back in dump order without duplicates")
    func presentKindsAreOrderedAndUnique() {
        let item = database(named: "app", objects: [
            ExportObjectItem(name: "t1", kind: .trigger, parentTable: "users"),
            ExportObjectItem(name: "users", kind: .table),
            ExportObjectItem(name: "posts", kind: .table),
            ExportObjectItem(name: "t2", kind: .trigger, parentTable: "posts")
        ])
        #expect(item.presentKinds == [.table, .trigger])
    }
}

@Suite("Export object option masking")
struct ExportObjectOptionMaskingTests {

    private let columns = [
        PluginExportOptionColumn(id: "structure", label: "Structure", width: 56),
        PluginExportOptionColumn(id: "drop", label: "Drop", width: 44),
        PluginExportOptionColumn(id: "data", label: "Data", width: 44)
    ]

    private func supportsOption(_ columnId: String, _ kind: PluginExportObjectKind) -> Bool {
        switch columnId {
        case "data": return kind.carriesRows
        case "drop": return kind != .grant
        default: return true
        }
    }

    /// The mask must clear in place rather than compact, or every option after the cleared one
    /// shifts and a routine's `Drop` flag is read as its `Data` flag.
    @Test("Masking clears an unsupported option without shifting the others")
    func maskingClearsInPlace() {
        let routine = ExportObjectItem(
            name: "recalc", kind: .routine, isSelected: true, optionValues: [true, true, true])
        let masked = routine.maskingUnsupportedOptions(columns: columns, supports: supportsOption)
        #expect(masked.optionValues == [true, true, false])
    }

    @Test("Masking leaves a table's options alone")
    func maskingLeavesTablesAlone() {
        let table = ExportObjectItem(
            name: "users", kind: .table, isSelected: true, optionValues: [true, false, true])
        let masked = table.maskingUnsupportedOptions(columns: columns, supports: supportsOption)
        #expect(masked.optionValues == [true, false, true])
    }

    @Test("A grant keeps only its structure flag")
    func grantKeepsStructureOnly() {
        let grant = ExportObjectItem(
            name: "app_user", kind: .grant, isSelected: true, optionValues: [true, true, true])
        let masked = grant.maskingUnsupportedOptions(columns: columns, supports: supportsOption)
        #expect(masked.optionValues == [true, false, false])
    }

    @Test("Masking a row whose option count does not match the columns leaves it untouched")
    func maskingIgnoresMismatchedShape() {
        let routine = ExportObjectItem(name: "recalc", kind: .routine, optionValues: [true])
        let masked = routine.maskingUnsupportedOptions(columns: columns, supports: supportsOption)
        #expect(masked.optionValues == [true])
    }

    @Test("Masking a whole tree reaches every object")
    func maskingReachesEveryObject() {
        let databases = [
            ExportDatabaseItem(name: "app", objects: [
                ExportObjectItem(name: "users", kind: .table, optionValues: [true, true, true]),
                ExportObjectItem(name: "recalc", kind: .routine, optionValues: [true, true, true])
            ])
        ]
        let masked = databases.maskingUnsupportedOptions(columns: columns, supports: supportsOption)
        #expect(masked[0].objects[0].optionValues == [true, true, true])
        #expect(masked[0].objects[1].optionValues == [true, true, false])
    }
}

@Suite("Export preselection with object kinds")
struct ExportPreselectionKindTests {

    /// A routine and a table can share a name, and a sidebar preselection is about tables. Without
    /// the kind check, selecting the `users` table would also tick a `users()` function.
    @Test("A table preselection never selects a routine of the same name")
    func tablePreselectionIgnoresRoutines() {
        let preselection = ExportPreselection.tables(["users"])
        #expect(preselection.selects(
            object: "users", kind: .table, inContainer: .database("app"), isCurrentContainer: true))
        #expect(!preselection.selects(
            object: "users", kind: .routine, inContainer: .database("app"), isCurrentContainer: true))
        #expect(!preselection.selects(
            object: "users", kind: .trigger, inContainer: .database("app"), isCurrentContainer: true))
    }

    @Test("A table preselection covers views and foreign tables")
    func tablePreselectionCoversViewShapes() {
        let preselection = ExportPreselection.tables(["users"])
        #expect(preselection.selects(
            object: "users", kind: .view, inContainer: .database("app"), isCurrentContainer: true))
        #expect(preselection.selects(
            object: "users", kind: .foreignTable, inContainer: .database("app"), isCurrentContainer: true))
    }

    @Test("A container preselection takes every kind in it")
    func containerPreselectionTakesEveryKind() {
        let preselection = ExportPreselection.containers([.database("app")])
        for kind in PluginExportObjectKind.allCases {
            #expect(preselection.selects(
                object: "anything", kind: kind, inContainer: .database("app"), isCurrentContainer: false),
                "\(kind) was not selected by a whole-container preselection")
        }
    }

    @Test("A container preselection does not reach another container")
    func containerPreselectionStaysInItsContainer() {
        let preselection = ExportPreselection.containers([.database("app")])
        #expect(!preselection.selects(
            object: "users", kind: .table, inContainer: .database("other"), isCurrentContainer: false))
    }
}
