//
//  RedisStatementGeneratorTests.swift
//  TableProTests
//
//  Tests for RedisStatementGenerator (compiled via symlink from RedisDriverPlugin).
//

import Foundation
import TableProPluginKit
import TableProRedisCore
import Testing

struct RedisStatementGeneratorTests {
    // MARK: - INSERT

    @Test("Basic insert generates a SET that refuses an existing key")
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
        #expect(results[0].statement == "MUSTAPPLY SET cache:mykey hello NX")
    }

    @Test("Insert with TTL sets the expiry in the same SET, so a refused insert never touches the existing key's TTL")
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

        #expect(results.count == 1)
        #expect(results[0].statement == "MUSTAPPLY SET session:abc data EX 3600 NX")
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
        #expect(results[0].statement == "MUSTAPPLY SET mykey value NX")
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

        #expect(results.map(\.statement) == ["MUSTAPPLY SET mykey value NX"])
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
        #expect(results[0].statement == "MUSTAPPLY SET mykey \"\" NX")
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
        #expect(results[0].statement == "MUSTAPPLY SET newkey newval NX")
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

    @Test("Update value generates a SET that keeps the key's TTL")
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
        #expect(results[0].statement == "SET mykey new KEEPTTL")
    }

    @Test("Update key writes the value to the old key, then renames only onto a free name")
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
        #expect(results[0].statement == "SET oldkey val2 KEEPTTL")
        #expect(results[1].statement == "MUSTAPPLY RENAMENX oldkey newkey")
    }

    @Test("Update key only (no value change) generates just the guarded rename")
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
        #expect(results[0].statement == "MUSTAPPLY RENAMENX oldkey newkey")
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

    @Test("A deleted key with a semicolon or an edge blank is quoted, so a history replay deletes that key", arguments: [
        "a;b", "user\u{A0}", "hello\u{3000}", "k\u{200B}"
    ])
    func deleteQuotesSeparatorsAndBlanks(key: String) throws {
        let gen = RedisStatementGenerator(namespaceName: "", columns: ["Key", "Value", "TTL"])
        let change = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.text(key), "v", "-1"])
        let results = try gen.generateRowWrites(
            from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )
        let statement = try #require(results.first?.statement)
        #expect(RedisCommandSplitter.commands(in: statement + ";").count == 1)
        let op = try RedisCommandParser.parse(statement + ";")
        guard case .del(let keys) = op else {
            Issue.record("Expected .del, got \(op)")
            return
        }
        #expect(keys == [key])
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
        #expect(results[0].statement == "MUSTAPPLY SET \"my key\" \"hello world\" NX")
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
        #expect(results[0].statement == "MUSTAPPLY SET key \"say \\\"hello\\\"\" NX")
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
        #expect(results[0].statement == "MUSTAPPLY SET newkey newval NX")
        #expect(results[1].statement == "SET existingkey new KEEPTTL")
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
        #expect(results[0].statement == "SET mykey new KEEPTTL")
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
        #expect(results[0].statement == "SET oldkey new KEEPTTL")
        #expect(results[1].statement == "EXPIRE oldkey 600")
        #expect(results[2].statement == "MUSTAPPLY RENAMENX oldkey newkey")
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
        #expect(results[0].statement == "SET mykey new KEEPTTL")
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
        #expect(results[0].statement == "SET mykey \(long) KEEPTTL")
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

        #expect(results.count == 1)
        #expect(results[0].statement == "MUSTAPPLY SET mykey hello EX 600 NX")
    }

    @Test("A new hash stores each JSON field value as the text it was written as")
    func hashInsertKeepsJSONValues() throws {
        var gen = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns)
        gen.stagingToken = { "t" }
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let value = #"{"s": "t", "n": 2, "on": true, "none": null, "nested": {"x": 1}, "list": [1, 2]}"#
        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [0: ["h", "hash", nil, nil, .text(value)]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        #expect(results.first?.statement
            == #"HSET h:tablepro-staging:t list [1,2] n 2 nested "{\"x\":1}" none null on true s t"#)
    }
}

// HSET, RPUSH, SADD and ZADD write into a key that already exists, so a new collection row is
// built under a staging key and moved onto its name only when the name is free.
struct RedisCollectionInsertTests {
    private static let browseColumns = ["Key", "Type", "TTL", "Length", "Value"]

    private func statements(key: String, type: String, ttl: PluginCellValue = nil, value: PluginCellValue) throws -> [String] {
        var gen = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns)
        gen.stagingToken = { "t" }
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        return try gen.generateRowWrites(
            from: [change],
            insertedRowData: [0: [.text(key), .text(type), ttl, nil, value]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        ).map { $0.statement }
    }

    @Test("Each collection type is built under a staging key and renamed only onto a free name", arguments: [
        ("list", "RPUSH queue:tablepro-staging:t job"),
        ("set", "SADD queue:tablepro-staging:t job"),
        ("zset", "ZADD queue:tablepro-staging:t 0 job"),
        ("hash", "HSET queue:tablepro-staging:t value job")
    ])
    func collectionInsertIsStaged(type: String, write: String) throws {
        #expect(try statements(key: "queue", type: type, value: "job") == [
            write,
            "MUSTAPPLY RENAMENX queue:tablepro-staging:t queue",
            "DEL queue:tablepro-staging:t"
        ])
    }

    @Test("The expiry is set on the staging key, which the rename carries over")
    func stagedInsertCarriesItsTTL() throws {
        #expect(try statements(key: "queue", type: "list", ttl: "60", value: "job") == [
            "RPUSH queue:tablepro-staging:t job",
            "EXPIRE queue:tablepro-staging:t 60",
            "MUSTAPPLY RENAMENX queue:tablepro-staging:t queue",
            "DEL queue:tablepro-staging:t"
        ])
    }

    @Test("A string insert keeps its single SET NX")
    func stringInsertIsNotStaged() throws {
        #expect(try statements(key: "queue", type: "string", value: "job") == ["MUSTAPPLY SET queue job NX"])
    }

    @Test("Every statement of a staged insert names the row it writes")
    func stagedStatementsNameTheRow() throws {
        var gen = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns)
        gen.stagingToken = { "t" }
        let change = PluginRowChange(rowIndex: 3, type: .insert, cellChanges: [], originalRow: nil)
        let writes = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [3: ["queue", "list", nil, nil, "job"]],
            deletedRowIndices: [],
            insertedRowIndices: [3]
        )
        #expect(writes.count == 3)
        #expect(writes.allSatisfy { $0.rowIndices == [3] })
    }

    // An ACL key pattern such as `~app:*` admits the staging key only when it starts with the key.
    @Test("On a cluster a staging key starts with its key and hashes to the key's slot", arguments: [
        "queue", "app:1", "user:{42}:profile", "{tenant}", "a}b", "{}x}", "x{", "}{", "user:{}{7}"
    ])
    func clusterStagingKeySharesTheSlot(key: String) throws {
        let staging = try #require(RedisConditionalWrite.stagingKey(for: key, token: "t", partitioned: true))
        #expect(staging.hasPrefix(key + RedisConditionalWrite.stagingMarker + "t"))
        #expect(RedisKeySlot.slot(for: staging) == RedisKeySlot.slot(for: key))
        #expect(RedisConditionalWrite.stagingToken(in: staging) == "t")
    }

    @Test("A tagged key keeps its tag, so its staging key needs no counter")
    func taggedKeyNeedsNoCounter() {
        #expect(RedisConditionalWrite.stagingKey(for: "user:{42}:profile", token: "t", partitioned: true)
            == "user:{42}:profile:tablepro-staging:t")
    }

    @Test("Without a cluster the staging key is the key and the marker, with no braces")
    func standaloneStagingKeyIsTheKeyWithASuffix() {
        #expect(RedisConditionalWrite.stagingKey(for: "app:1", token: "t", partitioned: false) == "app:1:tablepro-staging:t")
    }

    @Test("The grid on a cluster stages a key in its own slot")
    func clusterGridInsertIsStagedInTheKeysSlot() throws {
        var gen = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns, partitionsKeyspace: true)
        gen.stagingToken = { "t" }
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let statements = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [0: ["app:1", "list", nil, nil, "job"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        ).map { $0.statement }
        let staging = try #require(statements.first?.split(separator: " ").dropFirst().first.map(String.init))
        #expect(staging.hasPrefix("app:1:tablepro-staging:t"))
        #expect(RedisKeySlot.slot(for: staging) == RedisKeySlot.slot(for: "app:1"))
        #expect(statements.last == "DEL \(staging)")
    }

    @Test("The staging token is read past the last marker, without the slot counter")
    func stagingTokenIsReadPastTheLastMarker() {
        #expect(RedisConditionalWrite.stagingToken(in: "a:tablepro-staging:old:tablepro-staging:t.42") == "t")
        #expect(RedisConditionalWrite.stagingToken(in: "queue") == nil)
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
