//
//  GridColumnCatalogTests.swift
//  TableProTests
//

import Testing

@testable import TablePro

@Suite("Grid column catalog")
struct GridColumnCatalogTests {
    private let columns = ["id", "name", "created_at"]
    private let types: [ColumnType] = [
        .integer(rawType: "INTEGER"),
        .text(rawType: "VARCHAR(255)"),
        .timestamp(rawType: nil)
    ]

    @Test("Positions follow the grid's display order, not the result's")
    func positionsFollowDisplayOrder() {
        let entries = GridColumnCatalog.entries(
            resultColumns: columns,
            columnTypes: types,
            hiddenColumns: [],
            displayOrder: [2, 0, 1],
            pickerColumns: columns
        )

        #expect(entries.map(\.name) == columns)
        #expect(entries.map(\.position) == [2, 3, 1])
        #expect(entries.map(\.typeName) == ["INTEGER", "VARCHAR(255)", "Timestamp"])
        #expect(entries.map(\.dataIndex) == [0, 1, 2])
        #expect(entries.allSatisfy { !$0.isHidden })
    }

    @Test("A hidden result column keeps its data index and loses its position")
    func hiddenResultColumn() {
        let entries = GridColumnCatalog.entries(
            resultColumns: columns,
            columnTypes: types,
            hiddenColumns: ["name"],
            displayOrder: [0, 2],
            pickerColumns: columns
        )

        let name = entries[1]
        #expect(name.isHidden)
        #expect(name.dataIndex == 1)
        #expect(name.position == nil)
        #expect(name.typeName == "VARCHAR(255)")
        #expect(entries[2].position == 2)
    }

    @Test("A schema column the result left out is listed as hidden with no data index")
    func schemaOnlyHiddenColumn() {
        let entries = GridColumnCatalog.entries(
            resultColumns: ["id"],
            columnTypes: [types[0]],
            hiddenColumns: ["notes"],
            displayOrder: [0],
            pickerColumns: ["id", "notes"]
        )

        #expect(entries.map(\.name) == ["id", "notes"])
        let notes = entries[1]
        #expect(notes.isHidden)
        #expect(notes.dataIndex == nil)
        #expect(notes.typeName == nil)
        #expect(notes.position == nil)
        #expect(notes.id == "hidden-notes")
    }

    @Test("Without a mounted grid the result's order stands in for positions")
    func resultOrderWithoutAGrid() {
        let entries = GridColumnCatalog.entries(
            resultColumns: columns,
            columnTypes: types,
            hiddenColumns: ["name"],
            displayOrder: nil,
            pickerColumns: columns
        )

        #expect(entries.map(\.position) == [1, nil, 2])
    }

    @Test("Duplicate names get one entry per data index")
    func duplicateNames() {
        let entries = GridColumnCatalog.entries(
            resultColumns: ["id", "id"],
            columnTypes: [types[0], types[0]],
            hiddenColumns: [],
            displayOrder: nil,
            pickerColumns: ["id"]
        )

        #expect(entries.map(\.id) == ["column-0", "column-1"])
        #expect(entries.map(\.position) == [1, 2])
    }

    @Test("The visibility projection keeps one entry per name, the first in catalog order")
    func uniqueByName() {
        let entries = GridColumnCatalog.entries(
            resultColumns: ["id", "name", "id"],
            columnTypes: [types[0], types[1], types[2]],
            hiddenColumns: ["id"],
            displayOrder: nil,
            pickerColumns: ["id", "name"]
        )

        let unique = GridColumnCatalog.uniqueByName(entries)
        #expect(unique.map(\.name) == ["id", "name"])
        #expect(unique.first?.typeName == "INTEGER")
        #expect(unique.first?.isHidden == true)
    }

    @Test("Entries keep the picker's order and never drop a result column")
    func pickerOrder() {
        let entries = GridColumnCatalog.entries(
            resultColumns: ["a", "z", "extra"],
            columnTypes: [],
            hiddenColumns: [],
            displayOrder: nil,
            pickerColumns: ["z", "a"]
        )

        #expect(entries.map(\.name) == ["z", "a", "extra"])
        #expect(entries.map(\.typeName) == [nil, nil, nil])
    }
}
