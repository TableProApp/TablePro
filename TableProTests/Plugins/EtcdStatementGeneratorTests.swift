//
//  EtcdStatementGeneratorTests.swift
//  TableProTests
//
//  Tests for EtcdStatementGenerator (compiled via symlink from EtcdDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

// MARK: - INSERT

struct EtcdStatementGeneratorInsertTests {
    @Test("Basic insert generates put command")
    func basicInsert() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["mykey", "myvalue", nil, nil, nil, nil]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey myvalue")
    }

    @Test("Insert with lease generates put --lease")
    func insertWithLease() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["mykey", "myvalue", nil, nil, nil, "12345"]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey myvalue --lease=12345")
    }

    @Test("Insert with prefix prepending")
    func insertWithPrefixPrepending() throws {
        let gen = EtcdStatementGenerator(
            prefix: "/app/config/",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["setting1", "value1", nil, nil, nil, nil]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put /app/config/setting1 value1")
    }

    @Test("Insert with key already containing prefix (no double prefix)")
    func insertKeyAlreadyHasPrefix() throws {
        let gen = EtcdStatementGenerator(
            prefix: "/app/",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        // Key starts with "/" so it's treated as absolute
        let insertedData: [Int: [PluginCellValue]] = [
            0: ["/app/mykey", "value", nil, nil, nil, nil]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put /app/mykey value")
    }

    @Test("Insert with absolute key (leading slash) skips prefix prepend")
    func insertAbsoluteKey() throws {
        let gen = EtcdStatementGenerator(
            prefix: "something/",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["/absolute/key", "value", nil, nil, nil, nil]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put /absolute/key value")
    }

    @Test("Insert with empty key is refused")
    func insertEmptyKey() {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["", "value", nil, nil, nil, nil]
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

    @Test("Insert with nil key is refused")
    func insertNilKey() {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: [nil, "value", nil, nil, nil, nil]
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
    func insertNilValue() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["mykey", nil, nil, nil, nil, nil]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey \"\"")
    }

    @Test("Insert with lease=0 omits --lease flag")
    func insertLeaseZero() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["mykey", "value", nil, nil, nil, "0"]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(!results[0].statement.contains("--lease"))
    }

    @Test("Insert from cell changes (no insertedRowData)")
    func insertFromCellChanges() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
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
        #expect(results[0].statement == "put newkey newval")
    }

    @Test("Insert with value containing spaces is quoted")
    func insertValueWithSpaces() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["mykey", "hello world", nil, nil, nil, nil]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey \"hello world\"")
    }
}

// MARK: - UPDATE

struct EtcdStatementGeneratorUpdateTests {
    @Test("Value change generates put with original key")
    func valueChange() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "Value", oldValue: "oldval", newValue: "newval")
            ],
            originalRow: ["mykey", "oldval", "1", "1", "1", "0"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey newval")
    }

    @Test("Key rename generates put then del")
    func keyRename() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 0, columnName: "Key", oldValue: "oldkey", newValue: "newkey")
            ],
            originalRow: ["oldkey", "myvalue", "1", "1", "1", "0"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 2)
        #expect(results[0].statement == "put newkey myvalue")
        #expect(results[1].statement == "del oldkey")
    }

    @Test("Value and key change combined")
    func valueAndKeyChange() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 0, columnName: "Key", oldValue: "oldkey", newValue: "newkey"),
                (columnIndex: 1, columnName: "Value", oldValue: "oldval", newValue: "newval")
            ],
            originalRow: ["oldkey", "oldval", "1", "1", "1", "0"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 2)
        #expect(results[0].statement == "put newkey newval")
        #expect(results[1].statement == "del oldkey")
    }

    @Test("Lease change only generates put with --lease")
    func leaseChangeOnly() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 5, columnName: "Lease", oldValue: "0", newValue: "99999")
            ],
            originalRow: ["mykey", "myvalue", "1", "1", "1", "0"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey myvalue --lease=99999")
    }

    @Test("Value and lease change combined")
    func valueAndLeaseChange() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "Value", oldValue: "oldval", newValue: "newval"),
                (columnIndex: 5, columnName: "Lease", oldValue: "0", newValue: "555")
            ],
            originalRow: ["mykey", "oldval", "1", "1", "1", "0"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey newval --lease=555")
    }

    @Test("Update with empty new key is refused")
    func updateEmptyNewKey() {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 0, columnName: "Key", oldValue: "mykey", newValue: "")
            ],
            originalRow: ["mykey", "value", "1", "1", "1", "0"]
        )

        #expect(throws: PluginRowWriteRefusal(rowIndex: 0, reason: "A key needs a name.")) {
            try gen.generateRowWrites(
                from: [change],
                insertedRowData: [:],
                deletedRowIndices: [],
                insertedRowIndices: []
            )
        }
    }

    @Test("Update with no cell changes produces nothing")
    func updateNoCellChanges() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [],
            originalRow: ["mykey", "value", "1", "1", "1", "0"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("Update with lease set to 0 omits --lease flag")
    func updateLeaseToZero() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 5, columnName: "Lease", oldValue: "12345", newValue: "0")
            ],
            originalRow: ["mykey", "myvalue", "1", "1", "1", "12345"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(!results[0].statement.contains("--lease"))
    }
}

// MARK: - DELETE

struct EtcdStatementGeneratorDeleteTests {
    @Test("Basic delete generates del command")
    func basicDelete() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: ["mykey", "myvalue", "1", "1", "1", "0"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "del mykey")
    }

    @Test("Delete with key containing spaces is quoted")
    func deleteKeyWithSpaces() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: ["my key", "value", "1", "1", "1", "0"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "del \"my key\"")
    }

    @Test("Delete not in deletedRowIndices is skipped")
    func deleteNotInIndices() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: ["mykey", "value", "1", "1", "1", "0"]
        )

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }
}

// MARK: - Batch / Multiple Changes

struct EtcdStatementGeneratorBatchTests {
    @Test("Multiple changes in one batch")
    func multipleBatch() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let insertChange = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let updateChange = PluginRowChange(
            rowIndex: 1,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "Value", oldValue: "old", newValue: "new")
            ],
            originalRow: ["existingkey", "old", "1", "1", "1", "0"]
        )

        let deleteChange = PluginRowChange(
            rowIndex: 2,
            type: .delete,
            cellChanges: [],
            originalRow: ["delkey", "val", "1", "1", "1", "0"]
        )

        let insertedData: [Int: [PluginCellValue]] = [
            0: ["newkey", "newval", nil, nil, nil, nil]
        ]

        let results = try gen.generateRowWrites(
            from: [insertChange, updateChange, deleteChange],
            insertedRowData: insertedData,
            deletedRowIndices: [2],
            insertedRowIndices: [0]
        )

        #expect(results.count == 3)
        #expect(results[0].statement == "put newkey newval")
        #expect(results[1].statement == "put existingkey new")
        #expect(results[2].statement == "del delkey")
        #expect(results.map(\.rowIndices) == [[0], [1], [2]])
    }

    @Test("Insert not in insertedRowIndices is skipped")
    func insertNotInIndices() throws {
        let gen = EtcdStatementGenerator(
            prefix: "",
            columns: ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
        )

        let change = PluginRowChange(
            rowIndex: 5,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )

        let insertedData: [Int: [PluginCellValue]] = [
            5: ["key", "val", nil, nil, nil, nil]
        ]

        let results = try gen.generateRowWrites(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }
}

// MARK: - Values a put cannot carry

struct EtcdStatementGeneratorRefusalTests {
    private static let columns = ["Key", "Value", "Version", "CreateRevision", "ModRevision", "Lease"]
    private static let original: [PluginCellValue] = ["mykey", "oldval", "3", "1", "7", ""]

    private func writes(
        _ cells: [(columnIndex: Int, columnName: String, oldValue: PluginCellValue, newValue: PluginCellValue)],
        original: [PluginCellValue] = EtcdStatementGeneratorRefusalTests.original
    ) throws -> [PluginRowWrite] {
        try EtcdStatementGenerator(prefix: "", columns: Self.columns).generateRowWrites(
            from: [PluginRowChange(rowIndex: 0, type: .update, cellChanges: cells, originalRow: original)],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )
    }

    /// An empty value reads back as a NULL cell, so NULL is how the grid spells one.
    @Test("A Value set to NULL writes an empty value, never the old one")
    func nullValueWritesEmpty() throws {
        let written = try writes([(columnIndex: 1, columnName: "Value", oldValue: "oldval", newValue: .null)])
        #expect(written.map(\.statement) == ["put mykey \"\""])
        #expect(written.map(\.rowIndices) == [[0]])
    }

    @Test("A Lease set to NULL on its own removes the lease")
    func nullLeaseDetaches() throws {
        let written = try writes(
            [(columnIndex: 5, columnName: "Lease", oldValue: "7b", newValue: .null)],
            original: ["mykey", "oldval", "3", "1", "7", "7b"]
        )
        #expect(written.map(\.statement) == ["put mykey oldval"])
    }

    @Test("An edit to a column etcd sets is refused, even beside a Value edit it could write")
    func serverOwnedColumnRefused() {
        let refusal = PluginRowWriteRefusal(rowIndex: 0, reason: "'Version' is set by etcd and cannot be edited.")
        #expect(throws: refusal) {
            try writes([
                (columnIndex: 1, columnName: "Value", oldValue: "oldval", newValue: "newval"),
                (columnIndex: 2, columnName: "Version", oldValue: "3", newValue: "4"),
            ])
        }
    }

    @Test("A key renamed to NULL is refused rather than kept")
    func keyRenamedToNullRefused() {
        #expect(throws: PluginRowWriteRefusal(rowIndex: 0, reason: "A key needs a name.")) {
            try writes([
                (columnIndex: 0, columnName: "Key", oldValue: "mykey", newValue: .null),
                (columnIndex: 1, columnName: "Value", oldValue: "oldval", newValue: "newval"),
            ])
        }
    }

    @Test("A revision typed into a new row is refused, and a new row's NULL revision is not")
    func insertRevisionRefused() throws {
        let generator = EtcdStatementGenerator(prefix: "", columns: Self.columns)
        let typed = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [(columnIndex: 4, columnName: "ModRevision", oldValue: .null, newValue: "9")],
            originalRow: nil
        )
        let refusal = PluginRowWriteRefusal(rowIndex: 0, reason: "'ModRevision' is set by etcd and cannot be edited.")
        #expect(throws: refusal) {
            try generator.generateRowWrites(
                from: [typed],
                insertedRowData: [0: ["k", "v", nil, nil, "9", nil]],
                deletedRowIndices: [],
                insertedRowIndices: [0]
            )
        }

        let cleared = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [(columnIndex: 4, columnName: "ModRevision", oldValue: "9", newValue: .null)],
            originalRow: nil
        )
        let written = try generator.generateRowWrites(
            from: [cleared],
            insertedRowData: [0: ["k", "v", nil, nil, nil, nil]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        #expect(written.map(\.statement) == ["put k v"])
    }
}
