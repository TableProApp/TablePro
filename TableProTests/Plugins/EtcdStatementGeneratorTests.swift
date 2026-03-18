//
//  EtcdStatementGeneratorTests.swift
//  TableProTests
//
//  Tests for EtcdStatementGenerator (compiled via symlink from EtcdDriverPlugin).
//

import Foundation
import Testing
import TableProPluginKit

// MARK: - INSERT

@Suite("EtcdStatementGenerator - INSERT")
struct EtcdStatementGeneratorInsertTests {
    @Test("Basic insert generates put command")
    func basicInsert() {
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

        let insertedData: [Int: [String?]] = [
            0: ["mykey", "myvalue", nil, nil, nil, nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey myvalue")
    }

    @Test("Insert with lease generates put --lease")
    func insertWithLease() {
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

        let insertedData: [Int: [String?]] = [
            0: ["mykey", "myvalue", nil, nil, nil, "12345"]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey myvalue --lease=12345")
    }

    @Test("Insert with prefix prepending")
    func insertWithPrefixPrepending() {
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

        let insertedData: [Int: [String?]] = [
            0: ["setting1", "value1", nil, nil, nil, nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put /app/config/setting1 value1")
    }

    @Test("Insert with key already containing prefix (no double prefix)")
    func insertKeyAlreadyHasPrefix() {
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
        let insertedData: [Int: [String?]] = [
            0: ["/app/mykey", "value", nil, nil, nil, nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put /app/mykey value")
    }

    @Test("Insert with absolute key (leading slash) skips prefix prepend")
    func insertAbsoluteKey() {
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

        let insertedData: [Int: [String?]] = [
            0: ["/absolute/key", "value", nil, nil, nil, nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put /absolute/key value")
    }

    @Test("Insert with empty key is skipped")
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

        let insertedData: [Int: [String?]] = [
            0: ["", "value", nil, nil, nil, nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.isEmpty)
    }

    @Test("Insert with nil key is skipped")
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

        let insertedData: [Int: [String?]] = [
            0: [nil, "value", nil, nil, nil, nil]
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
    func insertNilValue() {
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

        let insertedData: [Int: [String?]] = [
            0: ["mykey", nil, nil, nil, nil, nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey \"\"")
    }

    @Test("Insert with lease=0 omits --lease flag")
    func insertLeaseZero() {
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

        let insertedData: [Int: [String?]] = [
            0: ["mykey", "value", nil, nil, nil, "0"]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(!results[0].statement.contains("--lease"))
    }

    @Test("Insert from cell changes (no insertedRowData)")
    func insertFromCellChanges() {
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

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put newkey newval")
    }

    @Test("Insert with value containing spaces is quoted")
    func insertValueWithSpaces() {
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

        let insertedData: [Int: [String?]] = [
            0: ["mykey", "hello world", nil, nil, nil, nil]
        ]

        let results = gen.generateStatements(
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

@Suite("EtcdStatementGenerator - UPDATE")
struct EtcdStatementGeneratorUpdateTests {
    @Test("Value change generates put with original key")
    func valueChange() {
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

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey newval")
    }

    @Test("Key rename generates put then del")
    func keyRename() {
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

        let results = gen.generateStatements(
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
    func valueAndKeyChange() {
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

        let results = gen.generateStatements(
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
    func leaseChangeOnly() {
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

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey myvalue --lease=99999")
    }

    @Test("Value and lease change combined")
    func valueAndLeaseChange() {
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

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "put mykey newval --lease=555")
    }

    @Test("Update with empty new key is skipped")
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

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("Update with no cell changes produces nothing")
    func updateNoCellChanges() {
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

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }

    @Test("Update with lease set to 0 omits --lease flag")
    func updateLeaseToZero() {
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

        let results = gen.generateStatements(
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

@Suite("EtcdStatementGenerator - DELETE")
struct EtcdStatementGeneratorDeleteTests {
    @Test("Basic delete generates del command")
    func basicDelete() {
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

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "del mykey")
    }

    @Test("Delete with key containing spaces is quoted")
    func deleteKeyWithSpaces() {
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

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(results.count == 1)
        #expect(results[0].statement == "del \"my key\"")
    }

    @Test("Delete not in deletedRowIndices is skipped")
    func deleteNotInIndices() {
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

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }
}

// MARK: - Batch / Multiple Changes

@Suite("EtcdStatementGenerator - Batch")
struct EtcdStatementGeneratorBatchTests {
    @Test("Multiple changes in one batch")
    func multipleBatch() {
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

        let insertedData: [Int: [String?]] = [
            0: ["newkey", "newval", nil, nil, nil, nil]
        ]

        let results = gen.generateStatements(
            from: [insertChange, updateChange, deleteChange],
            insertedRowData: insertedData,
            deletedRowIndices: [2],
            insertedRowIndices: [0]
        )

        #expect(results.count == 3)
        #expect(results[0].statement == "put newkey newval")
        #expect(results[1].statement == "put existingkey new")
        #expect(results[2].statement == "del delkey")
    }

    @Test("Insert not in insertedRowIndices is skipped")
    func insertNotInIndices() {
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

        let insertedData: [Int: [String?]] = [
            5: ["key", "val", nil, nil, nil, nil]
        ]

        let results = gen.generateStatements(
            from: [change],
            insertedRowData: insertedData,
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(results.isEmpty)
    }
}
