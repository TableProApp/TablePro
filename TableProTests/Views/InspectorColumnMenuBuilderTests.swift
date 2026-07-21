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
        let items = InspectorColumnMenuBuilder.structureItems(forColumn: 3, currentType: .text)

        #expect(items.count == 6)
        #expect(items[0].action == #selector(InspectorViewController.inspectorRenameColumn(_:)))
        #expect(items[1].action == #selector(InspectorViewController.inspectorInsertColumnBefore(_:)))
        #expect(items[2].action == #selector(InspectorViewController.inspectorInsertColumnAfter(_:)))
        #expect(items[3].submenu != nil)
        #expect(items[4].isSeparatorItem)
        #expect(items[5].action == #selector(InspectorViewController.inspectorDeleteColumn(_:)))

        for index in [0, 1, 2, 5] {
            #expect(items[index].tag == 3)
            #expect(items[index].target == nil)
        }
    }

    @Test("Delete Column is the last item, in its own trailing group")
    func deleteIsLastAfterSeparator() {
        let items = InspectorColumnMenuBuilder.structureItems(forColumn: 0, currentType: .integer)

        #expect(items.last?.action == #selector(InspectorViewController.inspectorDeleteColumn(_:)))
        #expect(items[items.count - 2].isSeparatorItem)
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
