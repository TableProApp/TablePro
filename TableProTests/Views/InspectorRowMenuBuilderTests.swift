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
            #expect(item.tag == 7)
            #expect(item.target == nil)
        }
    }
}
