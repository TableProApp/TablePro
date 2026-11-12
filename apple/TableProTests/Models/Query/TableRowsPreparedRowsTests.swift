//
//  TableRowsPreparedRowsTests.swift
//  TableProTests
//
//  A Fetch All or a large first page builds one Row per fetched row. That build runs off the main actor, and the main
//  actor only assigns the finished buffer, so a 2,000,000-row result no longer freezes the window while it is copied.
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct TableRowsPreparedRowsTests {
    private static let columns = ["id", "email"]
    private static let types: [ColumnType] = [.integer(rawType: nil), .text(rawType: nil)]
    private static let shape = TableRows.RowShape(columns: columns, masks: .none, exportPolicy: .none, exportTable: nil)

    private static func fetched(_ count: Int) -> [[PluginCellValue]] {
        (0 ..< count).map { [.text("\($0)"), .text("user\($0)@example.com")] }
    }

    private static func address(of rows: ContiguousArray<Row>) -> UnsafeRawPointer? {
        rows.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }

    @Test("Preparing a result reads every row off the main actor")
    func preparingReadsOffTheMainActor() async {
        let source = MainThreadReadCountingRows(base: Self.fetched(500))

        let prepared = await TableRows.preparing(source, shape: Self.shape)

        #expect(prepared.rows.count == 500)
        #expect(source.reads == MainThreadReadCountingRows.Reads(total: 500, onMain: 0))
    }

    @Test("The counting source sees reads made on the main actor")
    func countingSourceSeesMainActorReads() {
        let source = MainThreadReadCountingRows(base: Self.fetched(50))

        _ = TableRows.prepare(source, shape: Self.shape)

        #expect(source.reads == MainThreadReadCountingRows.Reads(total: 50, onMain: 50))
    }

    @Test("Installing prepared rows assigns the built buffer and its index instead of building them again")
    func installAdoptsTheBuiltBuffer() {
        var table = TableRows.from(queryRows: [[.text("0"), .text("old@example.com")]], columns: Self.columns, columnTypes: Self.types)
        let prepared = TableRows.prepare(
            Self.fetched(3), offset: 10, rowLocators: ["first", nil, "third"], shape: table.rowShape
        )

        #expect(table.install(prepared) == .fullReplace)
        #expect(Self.address(of: table.rows) == Self.address(of: prepared.rows))
        #expect(table.rows.map { $0.id } == [.existing(10), .existing(11), .existing(12)])
        #expect(table.index(of: .existing(12)) == 2)
        #expect(table.rowLocator(for: .existing(10)) == "first")
        #expect(table.rowLocator(for: .existing(11)) == nil)
        #expect(table.rowLocator(for: .existing(12)) == "third")
    }

    @Test("Rows prepared before a masking rule was saved are refused, and the held rows stay")
    func installRefusesRowsBuiltForOtherMasks() {
        var table = TableRows.from(queryRows: [[.text("0"), .text("old@example.com")]], columns: Self.columns, columnTypes: Self.types)
        let prepared = TableRows.prepare(Self.fetched(3), shape: table.rowShape)
        table.addMasks(ColumnMasks(styles: [1: .full]))

        #expect(table.install(prepared) == nil)
        #expect(table.rows.map { $0.id } == [.existing(0)])
        #expect(table.value(at: 0, column: 1) == ColumnMasks(styles: [1: .full]).value(.text("old@example.com"), column: 1))
    }

    @Test("Prepared rows install exactly what a replace builds: masks, padding, absent and unloaded cells, documents")
    func installMatchesReplace() {
        let masks = ColumnMasks(styles: [1: .email])
        let base = TableRows.from(
            queryRows: [[.text("0"), .text("old@example.com")]],
            columns: Self.columns,
            columnTypes: Self.types,
            masks: masks,
            exportTable: "users"
        )
        let incoming: [[PluginCellValue]] = [[.text("1"), .text("jane@example.com")], [.text("2")], [.text("3"), .null, .text("extra")]]
        let documents = incoming.indices.map { index in
            PluginExportDocument(fields: [PluginExportField(
                name: "email", canonicalJSON: "\"doc\(index)@example.com\"", typeName: "string", cellValue: .text("doc\(index)@example.com")
            )])
        }
        let absent: [Int: Set<Int>] = [1: [1]]
        let unloaded: [Int: [Int: Int]] = [2: [1: 4_000]]

        var replaced = base
        replaced.replace(rows: incoming, offset: 5, exportDocuments: documents, absentCells: absent, unloadedCells: unloaded)
        var installed = base
        let prepared = TableRows.prepare(
            incoming, offset: 5, exportDocuments: documents, absentCells: absent, unloadedCells: unloaded, shape: base.rowShape
        )

        #expect(installed.install(prepared) == .fullReplace)
        #expect(installed.rows == replaced.rows)
        #expect(installed.index(of: .existing(7)) == replaced.index(of: .existing(7)))
        #expect(installed.value(at: 0, column: 1) != .text("jane@example.com"))
    }

    // A Stop on a 2,000,000-row Fetch All left the tab on Loading until every row was built.
    @Test("A Stop during the off-main build ends it at the next interval, and what it built never installs")
    func stopEndsTheBuildWithinAnInterval() async {
        let interval = TableRows.cancellationCheckInterval
        let source = MainThreadReadCountingRows(base: Self.fetched(interval * 3), cancelsTaskAtRow: interval)

        let prepared = await Task { await TableRows.preparing(source, shape: Self.shape) }.value
        var table = TableRows.from(queryRows: [[.text("0"), .text("old@example.com")]], columns: Self.columns, columnTypes: Self.types)

        #expect(source.reads.total == interval * 2)
        #expect(!prepared.isComplete)
        #expect(prepared.rows.isEmpty)
        #expect(table.install(prepared) == nil)
        #expect(table.rows.map { $0.id } == [.existing(0)])
    }

    @Test("The build on the caller's actor lands every row even inside a stopped task")
    func callerBuildIgnoresAStop() async {
        let interval = TableRows.cancellationCheckInterval
        let source = MainThreadReadCountingRows(base: Self.fetched(interval * 2), cancelsTaskAtRow: 0)

        let prepared = await Task { TableRows.prepare(source, shape: Self.shape) }.value

        #expect(source.reads.total == interval * 2)
        #expect(prepared.isComplete)
        #expect(prepared.rows.count == interval * 2)
    }
}

// Counts which thread read each row, so a test can tell where a build ran.
private struct MainThreadReadCountingRows: RandomAccessCollection, Sendable {
    struct Reads: Equatable, Sendable {
        var total = 0
        var onMain = 0
    }

    let base: [[PluginCellValue]]
    // Cancels the task reading the row at this position, the way a Stop lands in the middle of a build.
    let cancelsTaskAtRow: Int?
    private let counter = OSAllocatedUnfairLock(initialState: Reads())

    init(base: [[PluginCellValue]], cancelsTaskAtRow: Int? = nil) {
        self.base = base
        self.cancelsTaskAtRow = cancelsTaskAtRow
    }

    var reads: Reads { counter.withLock { $0 } }
    var startIndex: Int { base.startIndex }
    var endIndex: Int { base.endIndex }

    subscript(position: Int) -> [PluginCellValue] {
        let onMain = Thread.isMainThread
        counter.withLock { counted in
            counted.total += 1
            if onMain { counted.onMain += 1 }
        }
        if position == cancelsTaskAtRow {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return base[position]
    }
}
