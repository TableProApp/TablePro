//
//  ERColumnRowTextTests.swift
//  TableProTests
//
//  A column row draws its name from the leading edge and its type to the trailing edge. Nothing
//  kept the two apart, so a long name ran under its type: "shipping_addr" over
//  "character varying(…".
//

import CoreGraphics
import Testing

@testable import TablePro

@MainActor
struct ERColumnRowTextTests {
    @Test("A long name and a long type share the row without touching")
    func longNameAndTypeDoNotOverlap() {
        let nodeWidth = ERDiagramLayout.nodeWidth
        let widths = ERDiagramNodeRenderer.columnTextWidths(
            name: "shipping_address",
            type: "character varying(255)",
            nodeWidth: nodeWidth
        )
        let unfitted = ERDiagramNodeRenderer.columnTextWidths(
            name: "shipping_address",
            type: "character varying(255)",
            nodeWidth: 10_000
        )
        let room = nodeWidth - 32 * ERDiagramLayout.typeScale

        #expect(widths.name == unfitted.name, "the name was cut although the type could give way")
        #expect(widths.type < unfitted.type, "the type was drawn whole into a row with no room for it")
        #expect(widths.name + widths.type + 8 * ERDiagramLayout.typeScale <= room + 0.5)
    }

    @Test("A short name leaves a long type its whole width")
    func shortNameLeavesTheTypeWhole() {
        let widths = ERDiagramNodeRenderer.columnTextWidths(
            name: "id",
            type: "timestamp with time zone",
            nodeWidth: ERDiagramLayout.nodeWidth
        )
        let unfitted = ERDiagramNodeRenderer.columnTextWidths(
            name: "id",
            type: "timestamp with time zone",
            nodeWidth: 10_000
        )
        #expect(widths == unfitted)
    }

    @Test("A name too long for the row keeps the type's first characters")
    func overlongNameLeavesTheTypeFloor() {
        let widths = ERColumnTextWidths(room: 180, gap: 8, name: 400, type: 120, typeFloor: 44)
        #expect(widths.type == 44)
        #expect(widths.name == 128)
    }

    @Test("A type narrower than the floor is reserved only its own width")
    func shortTypeReservesItsOwnWidth() {
        let widths = ERColumnTextWidths(room: 180, gap: 8, name: 400, type: 20, typeFloor: 44)
        #expect(widths.type == 20)
        #expect(widths.name == 152)
    }

    @Test("A row with no type gives the name all of its room")
    func untypedRowGivesTheNameEverything() {
        let widths = ERColumnTextWidths(room: 180, gap: 8, name: 400, type: 0, typeFloor: 44)
        #expect(widths.name == 180)
        #expect(widths.type == 0)
    }
}
