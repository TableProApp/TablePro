//
//  JSONRowInspectorViewModelTests.swift
//  TableProTests
//
//  What the JSON inspector does with a row that changes under it while a foreign key is still
//  being fetched. A rerun keeps a row's identity while its values move, so a fetched row held
//  against a node path is the wrong row the moment the values do.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
@Suite("JSONRowInspectorViewModel")
struct JSONRowInspectorViewModelTests {
    private static let connectionId = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID()

    private static let artistReference = JSONForeignKeyRef(
        column: "ArtistId",
        referencedTable: "Artist",
        referencedSchema: nil,
        referencedColumn: "ArtistId"
    )

    /// Hands a row back when the test says so rather than when the model asks, so a fetch can be
    /// held open across a rebuild the way a query blocked in a driver call is.
    @MainActor
    private final class FetchGate {
        private var pending: [CheckedContinuation<ForeignKeyRowFetcher.FetchedRow?, Error>] = []
        private(set) var callCount = 0

        func fetch() async throws -> ForeignKeyRowFetcher.FetchedRow? {
            callCount += 1
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }

        var pendingCount: Int { pending.count }

        func releaseFirst(with row: ForeignKeyRowFetcher.FetchedRow?) {
            guard !pending.isEmpty else { return }
            pending.removeFirst().resume(returning: row)
        }

        func releaseAll(with row: ForeignKeyRowFetcher.FetchedRow?) {
            let waiting = pending
            pending = []
            for continuation in waiting { continuation.resume(returning: row) }
        }
    }

    /// Lets the model's fetch task run up to its first suspension point, which is where it hands
    /// the gate its continuation. Nothing can be released before that has happened.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private static func snapshot(
        rowIdentity: String = "tab\u{001F}existing(0)",
        artistId: PluginCellValue = .text("1"),
        foreignKeys: [String: JSONForeignKeyRef] = ["ArtistId": artistReference]
    ) -> JSONRowSnapshot {
        JSONRowSnapshot(
            rowIdentity: rowIdentity,
            columns: ["AlbumId", "ArtistId"],
            columnTypes: [.integer(rawType: "INT"), .integer(rawType: "INT")],
            values: [.text("7"), artistId],
            foreignKeys: foreignKeys,
            connectionId: connectionId,
            databaseType: .sqlite
        )
    }

    private static func artistRow(name: String) -> ForeignKeyRowFetcher.FetchedRow {
        ForeignKeyRowFetcher.FetchedRow(
            columns: ["ArtistId", "Name"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")],
            values: [.text("1"), .text(name)],
            foreignKeys: [:]
        )
    }

    private func makeModel(gate: FetchGate) -> JSONRowInspectorViewModel {
        JSONRowInspectorViewModel { _, _, _, _ in try await gate.fetch() }
    }

    private func foreignKeyRow(in model: JSONRowInspectorViewModel) throws -> JSONDisplayRow {
        try #require(model.displayRows.first { $0.foreignKey != nil })
    }

    @Test("A fetched referenced row is dropped when the values under its key move")
    func rerunDropsFetchedRows() async throws {
        let gate = FetchGate()
        let model = makeModel(gate: gate)

        model.update(snapshot: Self.snapshot(artistId: .text("1")))
        let path = try foreignKeyRow(in: model).path
        model.toggle(row: try foreignKeyRow(in: model))
        await settle()
        gate.releaseFirst(with: Self.artistRow(name: "AC/DC"))
        await settle()
        #expect(model.states.fetched[path] != nil)

        /// The same row, rerun: the identity survives, the value under the key does not.
        model.update(snapshot: Self.snapshot(artistId: .text("2")))

        #expect(model.states.fetched.isEmpty, "Artist 1 must not stay printed under a key now holding 2")
        #expect(model.states.loading.isEmpty)
    }

    @Test("A fetch that returns after a rebuild writes nothing into the new tree")
    func lateFetchIsDiscarded() async throws {
        let gate = FetchGate()
        let model = makeModel(gate: gate)

        model.update(snapshot: Self.snapshot(artistId: .text("1")))
        model.toggle(row: try foreignKeyRow(in: model))
        await settle()
        #expect(gate.pendingCount == 1)

        model.update(snapshot: Self.snapshot(artistId: .text("2")))
        gate.releaseAll(with: Self.artistRow(name: "AC/DC"))
        await settle()

        #expect(model.states.fetched.isEmpty)
        #expect(model.states.failures.isEmpty)
    }

    @Test("A stale fetch completing late leaves the fetch that replaced it in hand")
    func staleCompletionKeepsTheReplacementFetch() async throws {
        let gate = FetchGate()
        let model = makeModel(gate: gate)

        model.update(snapshot: Self.snapshot(artistId: .text("1")))
        model.toggle(row: try foreignKeyRow(in: model))
        await settle()

        model.update(snapshot: Self.snapshot(artistId: .text("2")))
        model.toggle(row: try foreignKeyRow(in: model))
        await settle()
        #expect(gate.callCount == 2)

        /// Only the cancelled first query comes back. Its cleanup used to drop the second query's
        /// handle, which left the key looking unfetched and open to a third query for the same row.
        gate.releaseFirst(with: Self.artistRow(name: "Accept"))
        await settle()

        model.toggle(row: try foreignKeyRow(in: model))
        await settle()
        #expect(gate.callCount == 2, "A key with a fetch already in flight must not start a second one")
    }

    @Test("A NULL foreign key never fetches")
    func nullForeignKeyDoesNotFetch() async throws {
        let gate = FetchGate()
        let model = makeModel(gate: gate)

        model.update(snapshot: Self.snapshot(artistId: .null))

        let row = try foreignKeyRow(in: model)
        #expect(!row.isExpandable, "A key that references nothing offers no control")
        model.toggle(row: row)
        await settle()
        #expect(gate.callCount == 0)
    }

    @Test("Releasing data drops the tree and every row fetched for it")
    func releaseDataClearsEverything() async throws {
        let gate = FetchGate()
        let model = makeModel(gate: gate)

        model.update(snapshot: Self.snapshot())
        model.toggle(row: try foreignKeyRow(in: model))
        await settle()
        gate.releaseFirst(with: Self.artistRow(name: "AC/DC"))
        await settle()
        model.filterText = "Artist"

        model.releaseData()

        #expect(model.root == nil)
        #expect(model.states.fetched.isEmpty)
        #expect(model.filterText.isEmpty)
        #expect(model.displayRows.isEmpty)
    }

    @Test("An unchanged snapshot keeps the rows already fetched")
    func unchangedSnapshotKeepsFetchedRows() async throws {
        let gate = FetchGate()
        let model = makeModel(gate: gate)

        model.update(snapshot: Self.snapshot())
        let path = try foreignKeyRow(in: model).path
        model.toggle(row: try foreignKeyRow(in: model))
        await settle()
        gate.releaseFirst(with: Self.artistRow(name: "AC/DC"))
        await settle()

        model.update(snapshot: Self.snapshot())

        #expect(model.states.fetched[path] != nil)
    }

    @Test("A key that references a row already open in the chain reports the cycle")
    func repeatedVisitReportsACycle() async throws {
        let gate = FetchGate()
        let model = makeModel(gate: gate)

        model.update(snapshot: Self.snapshot(artistId: .text("1")))
        let path = try foreignKeyRow(in: model).path
        model.toggle(row: try foreignKeyRow(in: model))
        await settle()
        gate.releaseFirst(
            with: ForeignKeyRowFetcher.FetchedRow(
                columns: ["ArtistId"],
                columnTypes: [.integer(rawType: "INT")],
                values: [.text("1")],
                foreignKeys: ["ArtistId": Self.artistReference]
            )
        )
        await settle()

        let nested = try #require(model.displayRows.first { $0.foreignKey != nil && $0.path != path })
        model.toggle(row: nested)
        await settle()

        #expect(model.states.failures[nested.path] == .cycle)
        #expect(gate.callCount == 1, "A cycle is refused before it costs a query")
    }
}
