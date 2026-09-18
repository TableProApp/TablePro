//
//  DatabaseTreeDoubleClickIntentTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Database tree double-click intent")
struct DatabaseTreeDoubleClickIntentTests {
    private func tableRef(_ name: String, type: TableInfo.TableType = .table) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: "app",
            schema: "public",
            table: TableInfo(name: name, type: type, rowCount: nil, schema: "public")
        )
    }

    private func node(_ kind: DatabaseTreeNode.Kind) -> DatabaseTreeNode {
        DatabaseTreeNode(id: "n", kind: kind)
    }

    @Test("A table row opens permanently")
    func tableRowOpensPermanently() {
        let ref = tableRef("users")
        #expect(
            DatabaseTreeDoubleClickResolver.resolve(node: node(.table(ref)))
                == .openPermanently(ref)
        )
    }

    /// A Recent entry is a second row for a table the tree already lists, so the gesture has to
    /// mean the same thing there.
    @Test("A recent-table row opens permanently")
    func recentTableRowOpensPermanently() {
        let ref = tableRef("orders")
        #expect(
            DatabaseTreeDoubleClickResolver.resolve(node: node(.recentTable(ref)))
                == .openPermanently(ref)
        )
    }

    /// The one row that is both a table and a container. Disclosure belongs to the triangle and to
    /// the Right and Left arrows, so the row's own double-click still opens it.
    @Test("A partitioned table opens rather than disclosing, though it is expandable")
    func partitionedTableOpensRatherThanDiscloses() {
        let ref = tableRef("events", type: .partitionedTable)
        let partitioned = node(.table(ref))

        #expect(partitioned.isExpandable)
        #expect(DatabaseTreeDoubleClickResolver.resolve(node: partitioned) == .openPermanently(ref))
    }

    @Test("Container rows still toggle their disclosure")
    func containerRowsToggleDisclosure() {
        #expect(
            DatabaseTreeDoubleClickResolver.resolve(node: node(.database(.minimal(name: "shop"))))
                == .toggleDisclosure
        )
        #expect(
            DatabaseTreeDoubleClickResolver
                .resolve(node: node(.schema(database: "shop", schema: "public"))) == .toggleDisclosure
        )
        #expect(
            DatabaseTreeDoubleClickResolver.resolve(node: node(.recentSection)) == .toggleDisclosure
        )
    }

    @Test("A row that stands for nothing is ignored")
    func placeholderRowIsIgnored() {
        #expect(DatabaseTreeDoubleClickResolver.resolve(node: node(.status(.loading))) == .ignore)
    }
}
