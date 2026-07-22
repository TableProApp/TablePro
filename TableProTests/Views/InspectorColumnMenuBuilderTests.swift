//
//  InspectorColumnMenuBuilderTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("InspectorColumnMenuBuilder")
struct InspectorColumnMenuBuilderTests {
    @Test("Structure items route each action to the clicked column")
    func structureItemsWiring() {
        let items = InspectorColumnMenuBuilder.structureItems(
            forColumn: 3, currentType: .text, deleteColumns: [3], canMerge: true
        )

        #expect(items[0].action == #selector(InspectorViewController.inspectorRenameColumn(_:)))
        #expect(items[1].action == #selector(InspectorViewController.inspectorInsertColumnLeft(_:)))
        #expect(items[2].action == #selector(InspectorViewController.inspectorInsertColumnRight(_:)))
        #expect(items[3].action == #selector(InspectorViewController.inspectorSplitColumn(_:)))
        #expect(items[4].action == #selector(InspectorViewController.inspectorMergeColumns(_:)))
        #expect(items.last?.action == #selector(InspectorViewController.inspectorDeleteColumn(_:)))

        for item in items where !item.isSeparatorItem && item.submenu == nil {
            #expect(item.tag == 3)
            #expect(item.target == nil)
        }
    }

    @Test("Merge Columns is omitted for the last column")
    func mergeOmittedWhenNoNextColumn() {
        let withMerge = InspectorColumnMenuBuilder.structureItems(
            forColumn: 1, currentType: .text, deleteColumns: [1], canMerge: true
        )
        let withoutMerge = InspectorColumnMenuBuilder.structureItems(
            forColumn: 1, currentType: .text, deleteColumns: [1], canMerge: false
        )

        #expect(withMerge.contains { $0.action == #selector(InspectorViewController.inspectorMergeColumns(_:)) })
        #expect(!withoutMerge.contains { $0.action == #selector(InspectorViewController.inspectorMergeColumns(_:)) })
    }

    @Test("Delete Column is the last item, in its own trailing group")
    func deleteIsLastAfterSeparator() {
        let items = InspectorColumnMenuBuilder.structureItems(
            forColumn: 0, currentType: .integer, deleteColumns: [0], canMerge: false
        )

        #expect(items.last?.action == #selector(InspectorViewController.inspectorDeleteColumn(_:)))
        #expect(items[items.count - 2].isSeparatorItem)
    }

    @Test("Delete item carries the target columns and pluralizes its title")
    func deleteTargetsAndTitle() {
        let single = InspectorColumnMenuBuilder.structureItems(
            forColumn: 1, currentType: .text, deleteColumns: [1], canMerge: true
        )
        #expect(single.last?.representedObject as? [Int] == [1])
        #expect(single.last?.title == "Delete Column")

        let multi = InspectorColumnMenuBuilder.structureItems(
            forColumn: 1, currentType: .text, deleteColumns: [1, 2, 3], canMerge: true
        )
        #expect(multi.last?.representedObject as? [Int] == [1, 2, 3])
        #expect(multi.last?.title == "Delete Columns")
    }

    @Test("Type submenu checks the current type and offers Reset to Inferred")
    func typeSubmenuState() {
        let submenu = InspectorColumnMenuBuilder.typeSubmenu(forColumn: 1, currentType: .integer)

        let typeItems = submenu.items.filter { !$0.isSeparatorItem }
        #expect(typeItems.count == InspectorColumnType.allCases.count + 1)

        let checked = submenu.items.filter { $0.state == .on }
        #expect(checked.count == 1)
        let checkedAssignment = checked.first?.representedObject as? ColumnTypeAssignment
        #expect(checkedAssignment?.type == .integer)

        let reset = submenu.items.last
        #expect(reset?.action == #selector(InspectorViewController.inspectorSetColumnType(_:)))
        let resetAssignment = reset?.representedObject as? ColumnTypeAssignment
        #expect(resetAssignment != nil)
        #expect(resetAssignment?.type == nil)
    }
}
