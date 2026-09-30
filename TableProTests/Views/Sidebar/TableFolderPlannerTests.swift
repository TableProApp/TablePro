//
//  TableFolderPlannerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct TableFolderPlannerTests {
    private let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "public")

    private func table(_ name: String, type: TableInfo.TableType = .table) -> TableInfo {
        TableInfo(name: name, type: type, rowCount: nil, schema: "public")
    }

    private func layout(_ folders: [TableFolder], _ placements: [String: UUID]) -> TableFolderLayout {
        TableFolderLayout(folders: folders, placements: placements)
    }

    @Test("With no folders every object stays loose, in the order it came")
    func noFoldersKeepsOrder() {
        let tables = [table("orders"), table("customers")]
        let views = [table("sales", type: .view)]
        let plan = TableFolderPlanner.plan(objectsByKind: [.table: tables, .view: views], layout: .empty, searching: false)

        #expect(plan.entries.isEmpty)
        #expect(plan.looseObjects(of: .table) == tables)
        #expect(plan.looseObjects(of: .view) == views)
    }

    @Test("A filed object leaves its section and sits in its folder")
    func filedObjectsMoveIntoTheirFolder() {
        let billing = TableFolder(scope: scope, name: "Billing")
        let plan = TableFolderPlanner.plan(
            objectsByKind: [.table: [table("orders"), table("invoices"), table("payments")]],
            layout: layout([billing], ["invoices": billing.id, "payments": billing.id]),
            searching: false
        )

        #expect(plan.entries.map(\.folder) == [billing])
        #expect(plan.entries.first?.members.map(\.name) == ["invoices", "payments"])
        #expect(plan.looseObjects(of: .table).map(\.name) == ["orders"])
    }

    @Test("A folder holds tables and views together, sorted by name")
    func foldersMixKindsByName() {
        let billing = TableFolder(scope: scope, name: "Billing")
        let plan = TableFolderPlanner.plan(
            objectsByKind: [.table: [table("zeta"), table("mid")], .view: [table("alpha_view", type: .view)]],
            layout: layout([billing], ["zeta": billing.id, "alpha_view": billing.id, "mid": billing.id]),
            searching: false
        )

        #expect(plan.entries.first?.members.map(\.name) == ["alpha_view", "mid", "zeta"])
        #expect(plan.hasFiledObjects(of: .view))
        #expect(plan.hasFiledObjects(of: .table))
        #expect(plan.looseCount(of: .table) == 0)
    }

    @Test("An empty folder shows until a search leaves it out")
    func emptyFolderHidesWhileSearching() {
        let empty = TableFolder(scope: scope, name: "Empty")
        let objects: [SidebarObjectKind: [TableInfo]] = [.table: [table("orders")]]

        let browsing = TableFolderPlanner.plan(objectsByKind: objects, layout: layout([empty], [:]), searching: false)
        let searching = TableFolderPlanner.plan(objectsByKind: objects, layout: layout([empty], [:]), searching: true)

        #expect(browsing.entries.map(\.folder) == [empty])
        #expect(searching.entries.isEmpty)
    }

    @Test("A folder being named survives a search that matches nothing in it")
    func keptFolderSurvivesSearch() {
        let named = TableFolder(scope: scope, name: "New Folder")
        let plan = TableFolderPlanner.plan(
            objectsByKind: [.table: [table("orders")]],
            layout: layout([named], [:]),
            searching: true,
            keeping: [named.id]
        )

        #expect(plan.entries.map(\.folder) == [named])
    }

    @Test("Loose objects stay in their own kind's section")
    func looseObjectsStayByKind() {
        let plan = TableFolderPlanner.plan(
            objectsByKind: [.table: [table("orders"), table("customers")], .view: [table("sales", type: .view)]],
            layout: layout([TableFolder(scope: scope, name: "Unused")], [:]),
            searching: false
        )

        #expect(plan.looseObjects(of: .table).map(\.name) == ["orders", "customers"])
        #expect(plan.looseObjects(of: .view).map(\.name) == ["sales"])
        #expect(plan.looseObjects(of: .materializedView).isEmpty)
        #expect(!plan.hasFiledObjects(of: .table))
    }
}
