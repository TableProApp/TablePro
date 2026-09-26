//
//  RedisStatementGeneratorTests.swift
//  TableProTests
//
//  Tests for RedisStatementGenerator (compiled via symlink from RedisDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

struct RedisStatementGeneratorTests {
    // MARK: - INSERT

    @Test("Basic insert generates SET command")
    func basicInsert() throws {
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

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["cache:mykey", "hello", nil]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET cache:mykey hello")
    }

    @Test("Insert with TTL generates SET and EXPIRE")
    func insertWithTtl() throws {
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

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["session:abc", "data", "3600"]
        ]

        let results = try gen.generateRowWrites(
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
    func insertWithZeroTtl() throws {
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

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["mykey", "value", "0"]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET mykey value")
    }

    @Test("Insert with a negative TTL other than -1 is refused, not written without its expiry")
    func insertWithNegativeTtl() {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)

        #expect(throws: PluginRowWriteRefusal.self) {
            try gen.generateRowWrites(
                from: [change],
                insertedRowData: [0: ["mykey", "value", "-5"]],
                deletedRowIndices: [],
                insertedRowIndices: [0]
            )
        }
    }

    @Test("Insert with TTL -1 generates SET only")
    func insertWithNoExpiryTtl() throws {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [0: ["mykey", "value", "-1"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.map(\.statement) == ["SET mykey value"])
    }

    @Test("Insert without key is refused")
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

        let insertedData: [Int: [PluginCellValue]] = [
            0: [nil, "value", nil]
        ]

        #expect(throws: PluginRowWriteRefusal(rowIndex: 0, reason: "A new key needs a name.")) {
            try gen.generateRowWrites(
                from: [change],
                insertedRowData: insertedData,
                deletedRowIndices: [],
                insertedRowIndices: [0]
            )
        }
    }

    @Test("Insert with empty key is refused")
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

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["", "value", nil]
        ]

        #expect(throws: PluginRowWriteRefusal(rowIndex: 0, reason: "A new key needs a name.")) {
            try gen.generateRowWrites(
                from: [change],
                insertedRowData: insertedData,
                deletedRowIndices: [],
                insertedRowIndices: [0]
            )
        }
    }

    @Test("Insert with nil value uses empty string")
    func insertNilValueUsesEmpty() throws {
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

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["mykey", nil, nil]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET mykey \"\"")
    }

    @Test("Insert uses cellChanges as fallback")
    func insertFallbackToCellChanges() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET newkey newval")
    }

    @Test("Insert not in insertedRowIndices is skipped")
    func insertNotInIndices() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [5: ["key", "val", nil]],
            deletedRowIndices: [],
            insertedRowIndices: [0] // does not contain 5
        )

        #expect(results.isEmpty)
    }

    // MARK: - UPDATE

    @Test("Update value generates SET with new value")
    func updateValue() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET mykey new")
    }

    @Test("Update key generates RENAME then SET")
    func updateKey() throws {
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

        let results = try gen.generateRowWrites(
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
    func updateKeyOnly() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "RENAME oldkey newkey")
    }

    @Test("Update TTL generates EXPIRE")
    func updateTtl() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "EXPIRE mykey 7200")
    }

    @Test("Remove TTL (set to nil) generates PERSIST")
    func removeTtlNil() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "PERSIST mykey")
    }

    @Test("Remove TTL (set to -1) generates PERSIST")
    func removeTtlMinusOne() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "PERSIST mykey")
    }

    @Test("Update with empty cellChanges produces no statements")
    func updateEmptyCellChanges() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("Update without original row key is refused")
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

        let refusal = PluginRowWriteRefusal(
            rowIndex: 0, reason: "This key's name is not text, so it cannot be addressed from the grid."
        )
        #expect(throws: refusal) {
            try gen.generateRowWrites(
                from: [change],
                insertedRowData: [:],
                deletedRowIndices: [],
                insertedRowIndices: []
            )
        }
    }

    // MARK: - DELETE

    @Test("Single delete generates DEL command")
    func singleDelete() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "DEL mykey")
    }

    @Test("Bulk delete batches keys into single DEL command")
    func bulkDelete() throws {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"]
        )

        let changes = [
            PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["key1", "v1", "-1"]),
            PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: ["key2", "v2", "-1"]),
            PluginRowChange(rowIndex: 2, type: .delete, cellChanges: [], originalRow: ["key3", "v3", "-1"])
        ]

        let results = try gen.generateRowWrites(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0, 1, 2],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "DEL key1 key2 key3")
    }

    /// A cluster splits a DEL by slot, and one slot can refuse after another ran. Deleting a slot
    /// per statement makes each one all or nothing, so a save can say how many went through.
    @Test("On a partitioned keyspace each hash slot gets its own DEL")
    func deletePerHashSlot() throws {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"],
            deleteBatching: .perHashSlot
        )
        let changes = ["allowed:1", "forbidden:1", "{u}a", "{u}b"].enumerated().map { index, key in
            PluginRowChange(rowIndex: index, type: .delete, cellChanges: [], originalRow: [.text(key), "v", "-1"])
        }

        let results = try gen.generateRowWrites(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0, 1, 2, 3],
            insertedRowIndices: []
        )

        #expect(results.map(\.statement) == ["DEL allowed:1", "DEL forbidden:1", "DEL {u}a {u}b"])
    }

    @Test("Per-slot deletes quote each key the way a single DEL does")
    func deletePerHashSlotQuotes() throws {
        let gen = RedisStatementGenerator(
            namespaceName: "",
            columns: ["Key", "Value", "TTL"],
            deleteBatching: .perHashSlot
        )
        let changes = ["{s} one", "{s}\"two\""].enumerated().map { index, key in
            PluginRowChange(rowIndex: index, type: .delete, cellChanges: [], originalRow: [.text(key), "v", "-1"])
        }

        let results = try gen.generateRowWrites(
            from: changes,
            insertedRowData: [:],
            deletedRowIndices: [0, 1],
            insertedRowIndices: []
        )

        #expect(results.map(\.statement) == ["DEL \"{s} one\" \"{s}\\\"two\\\"\""])
    }

    @Test("Delete not in deletedRowIndices is skipped")
    func deleteNotInIndices() throws {
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

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0], // does not contain 5
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("Delete without original row key is refused")
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

        let refusal = PluginRowWriteRefusal(
            rowIndex: 0, reason: "This key's name is not text, so it cannot be addressed from the grid."
        )
        #expect(throws: refusal) {
            try gen.generateRowWrites(
                from: [change],
                insertedRowData: [:],
                deletedRowIndices: [0],
                insertedRowIndices: []
            )
        }
    }

    // MARK: - Values with Spaces

    @Test("Values with spaces are quoted")
    func valuesWithSpacesQuoted() throws {
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

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["my key", "hello world", nil]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET \"my key\" \"hello world\"")
    }

    @Test("Values with quotes are escaped")
    func valuesWithQuotesEscaped() throws {
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

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["key", "say \"hello\"", nil]
        ]

        let results = try gen.generateRowWrites(
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
    func mixedOperations() throws {
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

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["newkey", "newval", nil]
        ]

        let results = try gen.generateRowWrites(
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
    func updateValueAndTtl() throws {
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

        let results = try gen.generateRowWrites(
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
    func updateKeyValueAndTtl() throws {
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

        let results = try gen.generateRowWrites(
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

struct RedisStatementGeneratorBrowseColumnTests {
    private static let browseColumns = ["Key", "Type", "TTL", "Length", "Value"]

    @Test("A string value update still resolves with the Length column present")
    func valueUpdateWithLengthColumn() throws {
        let gen = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns)

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 4, columnName: "Value", oldValue: "old", newValue: "new")
            ],
            originalRow: ["mykey", "STRING", "-1", "3", "old"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET mykey new")
    }

    @Test("A whole string value is written back, however long it is")
    func longValueIsWrittenWhole() throws {
        let gen = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns)
        let long = String(repeating: "a", count: 5_000)

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 4, columnName: "Value", oldValue: "old", newValue: PluginCellValue.text(long))
            ],
            originalRow: ["mykey", "STRING", "-1", "3", "old"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "SET mykey \(long)")
    }

    @Test("A collection value update is refused so the structure survives")
    func collectionValueUpdateRefused() {
        let gen = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns)

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 4, columnName: "Value", oldValue: "[\"a\"]", newValue: "[\"b\"]")
            ],
            originalRow: ["mylist", "LIST", "-1", "1", "[\"a\"]"]
        )

        let refusal = PluginRowWriteRefusal(
            rowIndex: 0,
            reason: "The value of a list key cannot be edited in the grid. Change it with a command in the query editor."
        )
        #expect(throws: refusal) {
            try gen.generateRowWrites(
                from: [change],
                insertedRowData: [:],
                deletedRowIndices: [],
                insertedRowIndices: []
            )
        }
    }

    /// The Type cell is NULL when the server would not say, and `SET` over a hash the user cannot
    /// see replaces the hash.
    @Test("A value update on a key of unknown type is refused")
    func unknownTypeValueUpdateRefused() {
        let gen = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns)

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 4, columnName: "Value", oldValue: nil, newValue: "new")
            ],
            originalRow: ["other:h", nil, nil, nil, nil]
        )

        let refusal = PluginRowWriteRefusal(
            rowIndex: 0, reason: "The key's type is unknown, so its value cannot be written safely."
        )
        #expect(throws: refusal) {
            try gen.generateRowWrites(
                from: [change],
                insertedRowData: [:],
                deletedRowIndices: [],
                insertedRowIndices: []
            )
        }
    }

    @Test("A key of unknown type still takes a TTL change")
    func unknownTypeTtlUpdateApplies() throws {
        let gen = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns)

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 2, columnName: "TTL", oldValue: nil, newValue: "60")
            ],
            originalRow: ["other:h", nil, nil, nil, nil]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.map(\.statement) == ["EXPIRE other:h 60"])
    }

    @Test("An insert reads its cells by name, not by position")
    func insertResolvesColumnsByName() throws {
        let gen = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns)

        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let insertedData: [Int: [PluginCellValue]] = [
            0: ["mykey", "STRING", "600", nil, "hello"]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 2)
        #expect(results[0].statement == "SET mykey hello")
        #expect(results[1].statement == "EXPIRE mykey 600")
    }
}

struct RedisStatementGeneratorRefusalTests {
    private static let browseColumns = ["Key", "Type", "TTL", "Length", "Value"]
    private static let stringRow: [PluginCellValue] = ["mykey", "string", "-1", "3", "old"]
    private static let invalidTTL = "TTL has to be a whole number of seconds above 0, or -1 or NULL for no expiry."

    private func generator(batching: RedisDeleteBatching = .singleCommand) -> RedisStatementGenerator {
        RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns, deleteBatching: batching)
    }

    private func edit(
        _ cells: [(columnIndex: Int, columnName: String, oldValue: PluginCellValue, newValue: PluginCellValue)],
        original: [PluginCellValue] = RedisStatementGeneratorRefusalTests.stringRow
    ) -> PluginRowChange {
        PluginRowChange(rowIndex: 0, type: .update, cellChanges: cells, originalRow: original)
    }

    private func writes(for changes: [PluginRowChange], deleting: Set<Int> = []) throws -> [PluginRowWrite] {
        try generator().generateRowWrites(
            from: changes, insertedRowData: [:], deletedRowIndices: deleting, insertedRowIndices: []
        )
    }

    @Test("A Value edit on a list key refuses the row even beside a TTL edit it could write")
    func collectionValueBesideTtlRefusesTheRow() {
        let change = edit(
            [
                (columnIndex: 4, columnName: "Value", oldValue: "[\"a\"]", newValue: "[\"b\"]"),
                (columnIndex: 2, columnName: "TTL", oldValue: "-1", newValue: "60"),
            ],
            original: ["mylist", "list", "-1", "1", "[\"a\"]"]
        )
        let refusal = PluginRowWriteRefusal(
            rowIndex: 0,
            reason: "The value of a list key cannot be edited in the grid. Change it with a command in the query editor."
        )
        #expect(throws: refusal) { try writes(for: [change]) }
    }

    @Test("A Value set to NULL is refused")
    func nullValueRefused() {
        let change = edit([(columnIndex: 4, columnName: "Value", oldValue: "old", newValue: .null)])
        let refusal = PluginRowWriteRefusal(
            rowIndex: 0, reason: "Redis cannot store NULL as a value. Enter an empty value instead."
        )
        #expect(throws: refusal) { try writes(for: [change]) }
    }

    @Test("A TTL that is not a number of seconds above 0 is refused", arguments: ["0", "-5", "abc", ""])
    func invalidTtlUpdateRefused(ttl: String) {
        let change = edit([(columnIndex: 2, columnName: "TTL", oldValue: "-1", newValue: .text(ttl))])
        #expect(throws: PluginRowWriteRefusal(rowIndex: 0, reason: Self.invalidTTL)) { try writes(for: [change]) }
    }

    @Test("A new key whose TTL is not a number is refused")
    func invalidTtlInsertRefused() {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        #expect(throws: PluginRowWriteRefusal(rowIndex: 0, reason: Self.invalidTTL)) {
            try generator().generateRowWrites(
                from: [change],
                insertedRowData: [0: ["k", "string", "soon", .null, "v"]],
                deletedRowIndices: [],
                insertedRowIndices: [0]
            )
        }
    }

    @Test("A new key of a type the grid cannot build is refused")
    func unsupportedInsertTypeRefused() {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let refusal = PluginRowWriteRefusal(
            rowIndex: 0,
            reason: "A stream key cannot be added from the grid. Add it with a command in the query editor."
        )
        #expect(throws: refusal) {
            try generator().generateRowWrites(
                from: [change],
                insertedRowData: [0: ["events", "STREAM", .null, .null, "x"]],
                deletedRowIndices: [],
                insertedRowIndices: [0]
            )
        }
    }

    @Test("A Type edit on an existing key is refused")
    func typeEditRefused() {
        let change = edit([
            (columnIndex: 4, columnName: "Value", oldValue: "old", newValue: "new"),
            (columnIndex: 1, columnName: "Type", oldValue: "string", newValue: "hash"),
        ])
        let refusal = PluginRowWriteRefusal(rowIndex: 0, reason: "'Type' cannot be changed from the grid.")
        #expect(throws: refusal) { try writes(for: [change]) }
    }

    @Test("A key renamed to NULL is refused")
    func keyRenamedToNullRefused() {
        let change = edit([
            (columnIndex: 0, columnName: "Key", oldValue: "mykey", newValue: .null),
            (columnIndex: 4, columnName: "Value", oldValue: "old", newValue: "new"),
        ])
        let refusal = PluginRowWriteRefusal(rowIndex: 0, reason: "A key can only be renamed to text.")
        #expect(throws: refusal) { try writes(for: [change]) }
    }

    @Test("Every command names the change it writes, and a per-slot DEL names the rows in its slot")
    func writesNameTheirChanges() throws {
        let row: (String) -> [PluginCellValue] = { [.text($0), "string", "-1", "1", "v"] }
        let changes = [
            edit([(columnIndex: 2, columnName: "TTL", oldValue: "-1", newValue: "60")]),
            PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: row("{u}a")),
            PluginRowChange(rowIndex: 2, type: .delete, cellChanges: [], originalRow: row("x")),
            PluginRowChange(rowIndex: 3, type: .delete, cellChanges: [], originalRow: row("{u}b")),
        ]
        let written = try generator(batching: .perHashSlot).generateRowWrites(
            from: changes, insertedRowData: [:], deletedRowIndices: [1, 2, 3], insertedRowIndices: []
        )
        #expect(written.map(\.statement) == ["EXPIRE mykey 60", "DEL {u}a {u}b", "DEL x"])
        #expect(written.map(\.rowIndices) == [[0], [1, 3], [2]])
    }
}
