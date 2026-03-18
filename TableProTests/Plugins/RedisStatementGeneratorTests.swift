//
//  RedisStatementGeneratorTests.swift
//  TableProTests
//
//  Tests for RedisStatementGenerator (compiled via symlink from RedisDriverPlugin).
//

import Foundation
import Testing
import TableProPluginKit

@Suite("Redis Statement Generator")
struct RedisStatementGeneratorTests {

    // MARK: - INSERT

    @Test("Basic insert generates SET command")
    func basicInsert() {
        let gen = RedisStatementGenerator(
            namespaceName: "cache:",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: ["cache:mykey", "hello", nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET cache:mykey hello")
    }

    @Test("Insert with TTL generates SET and EXPIRE")
    func insertWithTtl() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: ["session:abc", "data", "3600"]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 2)
        #expect(results[0].statement == "SET session:abc data")
        #expect(results[1].statement == "EXPIRE session:abc 3600")
    }

    @Test("Insert with TTL=0 generates SET only")
    func insertWithZeroTtl() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: ["mykey", "value", "0"]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET mykey value")
    }

    @Test("Insert without key is skipped")
    func insertWithoutKey() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: [nil, "value", nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.isEmpty)
    }

    @Test("Insert with empty key is skipped")
    func insertEmptyKey() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: ["", "value", nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.isEmpty)
    }

    @Test("Insert with nil value uses empty string")
    func insertNilValueUsesEmpty() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: ["mykey", nil, nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET mykey \"\"")
    }

    @Test("Insert uses cellChanges as fallback")
    func insertFallbackToCellChanges() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [
                (columnIndex: 0, columnName: "Key", oldValue: nil, newValue: "newkey"),
                (columnIndex: 1, columnName: "Value", oldValue: nil, newValue: "newval")
            ],
            originalRow: nil
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET newkey newval")
    }

    @Test("Insert not in insertedRowIndices is skipped")
    func insertNotInIndices() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 5,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [5: ["key", "val", nil]],
            deletedRowIndices: [],
            insertedRowIndices: [0] // does not contain 5
        )

        #expect(results.isEmpty)
    }

    // MARK: - UPDATE

    @Test("Update value generates SET with new value")
    func updateValue() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "Value", oldValue: "old", newValue: "new")
            ],
            originalRow: ["mykey", "old", "3600"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET mykey new")
    }

    @Test("Update key generates RENAME then SET")
    func updateKey() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 0, columnName: "Key", oldValue: "oldkey", newValue: "newkey"),
                (columnIndex: 1, columnName: "Value", oldValue: "val", newValue: "val2")
            ],
            originalRow: ["oldkey", "val", "-1"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 2)
        #expect(results[0].statement == "RENAME oldkey newkey")
        #expect(results[1].statement == "SET newkey val2")
    }

    @Test("Update key only (no value change) generates just RENAME")
    func updateKeyOnly() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 0, columnName: "Key", oldValue: "oldkey", newValue: "newkey")
            ],
            originalRow: ["oldkey", "val", "-1"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "RENAME oldkey newkey")
    }

    @Test("Update TTL generates EXPIRE")
    func updateTtl() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 2, columnName: "TTL", oldValue: "3600", newValue: "7200")
            ],
            originalRow: ["mykey", "value", "3600"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "EXPIRE mykey 7200")
    }

    @Test("Remove TTL (set to nil) generates PERSIST")
    func removeTtlNil() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 2, columnName: "TTL", oldValue: "3600", newValue: nil)
            ],
            originalRow: ["mykey", "value", "3600"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "PERSIST mykey")
    }

    @Test("Remove TTL (set to -1) generates PERSIST")
    func removeTtlMinusOne() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 2, columnName: "TTL", oldValue: "3600", newValue: "-1")
            ],
            originalRow: ["mykey", "value", "3600"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "PERSIST mykey")
    }

    @Test("Update with empty cellChanges produces no statements")
    func updateEmptyCellChanges() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [],
            originalRow: ["mykey", "value", "-1"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("Update without original row key is skipped")
    func updateNoKey() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "Value", oldValue: "a", newValue: "b")
            ],
            originalRow: nil
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    // MARK: - DELETE

    @Test("Single delete generates DEL command")
    func singleDelete() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: ["mykey", "value", "-1"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "DEL mykey")
    }

    @Test("Bulk delete batches keys into single DEL command")
    func bulkDelete() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let changes = [
            PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["key1", "v1", "-1"]),
            PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: ["key2", "v2", "-1"]),
            PluginRowChange(rowIndex: 2, type: .delete, cellChanges: [], originalRow: ["key3", "v3", "-1"])
        ]

        let results = gen.generateStatements(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0, 1, 2],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "DEL key1 key2 key3")
    }

    @Test("Delete not in deletedRowIndices is skipped")
    func deleteNotInIndices() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 5,
            type: .delete,
            cellChanges: [],
            originalRow: ["mykey", "val", "-1"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0], // does not contain 5
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("Delete without original row key is skipped")
    func deleteNoOriginalRow() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: nil
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    // MARK: - Values with Spaces

    @Test("Values with spaces are quoted")
    func valuesWithSpacesQuoted() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: ["my key", "hello world", nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET \"my key\" \"hello world\"")
    }

    @Test("Values with quotes are escaped")
    func valuesWithQuotesEscaped() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [String?]] = [
            0: ["key", "say \"hello\"", nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET key \"say \\\"hello\\\"\"")
    }

    // MARK: - Mixed Operations

    @Test("Mixed insert, update, and delete in one batch")
    func mixedOperations() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let changes = [
            PluginRowChange(
                rowIndex: 0,
                type: .insert,
                cellChanges: [],
                originalRow: nil
            ),
            PluginRowChange(
                rowIndex: 1,
                type: .update,
                cellChanges: [
                    (columnIndex: 1, columnName: "Value", oldValue: "old", newValue: "new")
                ],
                originalRow: ["existingkey", "old", "-1"]
            ),
            PluginRowChange(
                rowIndex: 2,
                type: .delete,
                cellChanges: [],
                originalRow: ["delkey", "val", "-1"]
            )
        ]

        let insertedData: [Int: [String?]] = [
            0: ["newkey", "newval", nil]
        ]

        let results = gen.generateStatements(
            from: changes,
            insertedRowData: insertedData,
            deletedRowIndices: [2],
            insertedRowIndices: [0]
        )

        #expect(results.count == 3)
        #expect(results[0].statement == "SET newkey newval")
        #expect(results[1].statement == "SET existingkey new")
        #expect(results[2].statement == "DEL delkey")
    }

    @Test("Update value and TTL together")
    func updateValueAndTtl() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "Value", oldValue: "old", newValue: "new"),
                (columnIndex: 2, columnName: "TTL", oldValue: "-1", newValue: "300")
            ],
            originalRow: ["mykey", "old", "-1"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 2)
        #expect(results[0].statement == "SET mykey new")
        #expect(results[1].statement == "EXPIRE mykey 300")
    }

    @Test("Update key, value, and TTL together")
    func updateKeyValueAndTtl() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 0, columnName: "Key", oldValue: "oldkey", newValue: "newkey"),
                (columnIndex: 1, columnName: "Value", oldValue: "old", newValue: "new"),
                (columnIndex: 2, columnName: "TTL", oldValue: "-1", newValue: "600")
            ],
            originalRow: ["oldkey", "old", "-1"]
        )

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 3)
        #expect(results[0].statement == "RENAME oldkey newkey")
        #expect(results[1].statement == "SET newkey new")
        #expect(results[2].statement == "EXPIRE newkey 600")
    }
}
