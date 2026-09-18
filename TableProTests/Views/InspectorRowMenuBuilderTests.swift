//
//  InspectorRowMenuBuilderTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
@Suite("InspectorRowMenuBuilder")
struct InspectorRowMenuBuilderTests {
    @Test("Structure items are Insert Row Above then Insert Row Below")
    func structureItemsOrder() {
        let items = InspectorRowMenuBuilder.structureItems(forRow: 4)

        #expect(items.count == 2)
        #expect(items[0].action == #selector(InspectorViewController.inspectorInsertRowAbove(_:)))
        #expect(items[1].action == #selector(InspectorViewController.inspectorInsertRowBelow(_:)))
    }

    @Test("Each item carries the clicked row and no explicit target")
    func structureItemsWiring() {
        let items = InspectorRowMenuBuilder.structureItems(forRow: 7)

        for item in items {
            #expect(item.representedObject as? Int == 7)
            #expect(item.target == nil)
        }
    }

    @Test("A context menu item anchors on the row it carries, not on the selection")
    func contextMenuSenderAnchorsOnClickedRow() {
        let items = InspectorRowMenuBuilder.structureItems(forRow: 3)

        #expect(InspectorRowMenuBuilder.insertAnchorDisplayRow(
            sender: items[0], selectedDisplayRows: [8, 9], below: false
        ) == 3)
        #expect(InspectorRowMenuBuilder.insertAnchorDisplayRow(
            sender: items[1], selectedDisplayRows: [8, 9], below: true
        ) == 3)
    }

    @Test("A menu bar sender carrying no row falls back to the selection")
    func menuBarSenderFallsBackToSelection() {
        let sender = MenuItemFactory.item(
            "Insert Row Above",
            action: #selector(InspectorViewController.inspectorInsertRowAbove(_:))
        )
        let carriedRow = sender.representedObject as? Int
        #expect(carriedRow == nil)

        #expect(InspectorRowMenuBuilder.insertAnchorDisplayRow(
            sender: sender, selectedDisplayRows: [2, 5], below: false
        ) == 2)
        #expect(InspectorRowMenuBuilder.insertAnchorDisplayRow(
            sender: sender, selectedDisplayRows: [2, 5], below: true
        ) == 5)
    }

    @Test("A row zero anchor survives, and no anchor with no selection stays absent")
    func zeroRowAnchorAndEmptySelection() {
        let items = InspectorRowMenuBuilder.structureItems(forRow: 0)
        #expect(InspectorRowMenuBuilder.insertAnchorDisplayRow(
            sender: items[0], selectedDisplayRows: [], below: false
        ) == 0)

        #expect(InspectorRowMenuBuilder.insertAnchorDisplayRow(
            sender: nil, selectedDisplayRows: [], below: false
        ) == nil)
        #expect(InspectorRowMenuBuilder.insertAnchorDisplayRow(
            sender: NSMenuItem(), selectedDisplayRows: [], below: true
        ) == nil)
    }
}
