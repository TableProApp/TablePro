//
//  JSONRowInspectorViewModelTests.swift
//  TableProTests
//
//  What the JSON inspector does with a row that changes under it while a foreign key is still
//  being fetched. A rerun keeps a row's identity while its values move, so a fetched row held
//  against a node path is the wrong row the moment the values do.
//

import AppKit
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class JSONInspectorClipboard: ClipboardProvider {
    var texts: [String] = []

    func readText() -> String? { texts.last }
    func readGridRows() -> GridRowsClipboardPayload? { nil }
    func writeText(_ text: String) { texts.append(text) }
    func writeCsv(_ csv: String) {}
    func writeImage(_ image: NSImage) {}
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) {}
    var hasText: Bool { !texts.isEmpty }
    var hasGridRows: Bool { false }
}

@MainActor
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
            scope: DatabaseScope(connectionId: connectionId, database: "main", schema: nil),
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

    /// A row with one nested document, so there is a container to close besides the root.
    private static func documentSnapshot(rowIdentity: String = "tab\u{001F}existing(0)") -> JSONRowSnapshot {
        JSONRowSnapshot(
            rowIdentity: rowIdentity,
            columns: ["id", "meta"],
            columnTypes: [.integer(rawType: "INT"), .json(rawType: "JSON")],
            values: [.text("7"), .text("{\"color\": \"teal\", \"size\": \"xl\"}")],
            foreignKeys: [:],
            scope: DatabaseScope(connectionId: connectionId, database: "main", schema: nil),
            databaseType: .sqlite
        )
    }

    private func makeModel(gate: FetchGate) -> JSONRowInspectorViewModel {
        JSONRowInspectorViewModel { _, _, _, _ in try await gate.fetch() }
    }

    private func metaRow(in model: JSONRowInspectorViewModel) throws -> JSONDisplayRow {
        try #require(model.displayRows.first { $0.key == .name("meta") && $0.token != .closeObject })
    }

    private func keys(in model: JSONRowInspectorViewModel) -> [String] {
        model.displayRows.filter { $0.showsKey }.compactMap { $0.key.text }
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

    // MARK: - Under a filter

    @Test("A click under a filter closes the line it was made on and leaves the stored expansion alone")
    func toggleUnderAFilterDoesNotReachTheStoredExpansion() throws {
        let model = makeModel(gate: FetchGate())
        model.update(snapshot: Self.documentSnapshot())
        let unfiltered = model.displayRows

        model.filterText = "teal"
        #expect(keys(in: model) == ["meta", "color"])

        model.toggle(row: try metaRow(in: model))
        #expect(try metaRow(in: model).token == .collapsedObject(count: 1), "The click has to do something")
        #expect(keys(in: model) == ["meta"])

        model.filterText = ""
        #expect(model.displayRows == unfiltered, "What was open before the filter is open after it")
    }

    @Test("A line closed under a filter opens again on the next click")
    func toggleUnderAFilterReopens() throws {
        let model = makeModel(gate: FetchGate())
        model.update(snapshot: Self.documentSnapshot())
        model.filterText = "teal"
        let filtered = model.displayRows

        model.toggle(row: try metaRow(in: model))
        #expect(try metaRow(in: model).isExpandable, "A closed line keeps the control that opens it")
        #expect(model.displayRows != filtered)
        model.toggle(row: try metaRow(in: model))

        #expect(model.displayRows == filtered)
    }

    /// A filter opens everything it kept. A line closed under the last query would hide the
    /// match the new one found.
    @Test("A new query forgets what was closed under the last one")
    func newQueryForgetsWhatWasClosed() throws {
        let model = makeModel(gate: FetchGate())
        model.update(snapshot: Self.documentSnapshot())
        model.filterText = "te"
        model.toggle(row: try metaRow(in: model))
        #expect(keys(in: model) == ["meta"])

        model.filterText = "teal"

        #expect(keys(in: model) == ["meta", "color"])
    }

    @Test("Another row forgets what was closed under the filter")
    func anotherRowForgetsWhatWasClosed() throws {
        let model = makeModel(gate: FetchGate())
        model.update(snapshot: Self.documentSnapshot())
        model.filterText = "teal"
        model.toggle(row: try metaRow(in: model))
        #expect(keys(in: model) == ["meta"])

        model.update(snapshot: Self.documentSnapshot(rowIdentity: "tab\u{001F}existing(1)"))

        #expect(keys(in: model) == ["meta", "color"])
    }

    @Test("Collapse All and Expand All under a filter act on what the filter shows")
    func collapseAndExpandAllUnderAFilter() throws {
        let model = makeModel(gate: FetchGate())
        model.update(snapshot: Self.documentSnapshot())
        let unfiltered = model.displayRows
        model.filterText = "teal"
        let filtered = model.displayRows

        model.collapseAll()
        #expect(model.displayRows.map { $0.token } == [.collapsedObject(count: 1)])

        model.expandAll()
        #expect(model.displayRows == filtered)

        model.collapseAll()
        model.filterText = ""
        #expect(model.displayRows == unfiltered, "Collapse All under a filter must not close the unfiltered tree")
    }

    /// The fetched row would be filtered out again, so the click would cost a query to show nothing.
    @Test("A foreign key the filter kept for its value costs no query")
    func valueMatchedForeignKeyDoesNotFetch() async throws {
        let gate = FetchGate()
        let model = makeModel(gate: gate)
        model.update(snapshot: Self.snapshot(artistId: .text("1")))
        model.filterText = "1"

        let row = try foreignKeyRow(in: model)
        #expect(!row.isExpandable)
        model.toggle(row: row)
        await settle()

        #expect(gate.callCount == 0)
        #expect(model.states.loading.isEmpty)
    }

    @Test("A foreign key the filter kept for its key still fetches, and its row is shown")
    func keyMatchedForeignKeyFetchesUnderAFilter() async throws {
        let gate = FetchGate()
        let model = makeModel(gate: gate)
        model.update(snapshot: Self.snapshot(artistId: .text("1")))
        model.filterText = "artist"

        model.toggle(row: try foreignKeyRow(in: model))
        await settle()
        gate.releaseFirst(with: Self.artistRow(name: "AC/DC"))
        await settle()

        #expect(gate.callCount == 1)
        #expect(keys(in: model) == ["ArtistId", "ArtistId", "Name"])
    }

    @Test("A foreign key fetched under a filter can be closed there and is still open without it")
    func fetchedForeignKeyClosesUnderAFilter() async throws {
        let gate = FetchGate()
        let model = makeModel(gate: gate)
        model.update(snapshot: Self.snapshot(artistId: .text("1")))
        model.filterText = "artist"
        model.toggle(row: try foreignKeyRow(in: model))
        await settle()
        gate.releaseFirst(with: Self.artistRow(name: "AC/DC"))
        await settle()

        model.toggle(row: try foreignKeyRow(in: model))
        #expect(keys(in: model) == ["ArtistId"])
        #expect(gate.callCount == 1, "Closing a fetched key is not another query")

        model.filterText = ""
        #expect(keys(in: model) == ["AlbumId", "ArtistId", "ArtistId", "Name"])
    }

    /// A rerun drops the fetched row and keeps the row's identity, so the key is back to
    /// unfetched with the reader's close still recorded against its path.
    @Test("A key closed under a filter shows its row when it is fetched again")
    func refetchedForeignKeyOpensUnderAFilter() async throws {
        let gate = FetchGate()
        let model = makeModel(gate: gate)
        model.update(snapshot: Self.snapshot(artistId: .text("1")))
        model.filterText = "artist"
        model.toggle(row: try foreignKeyRow(in: model))
        await settle()
        gate.releaseFirst(with: Self.artistRow(name: "AC/DC"))
        await settle()
        model.toggle(row: try foreignKeyRow(in: model))
        #expect(keys(in: model) == ["ArtistId"])

        model.update(snapshot: Self.snapshot(artistId: .text("2")))
        model.toggle(row: try foreignKeyRow(in: model))
        await settle()
        gate.releaseFirst(with: Self.artistRow(name: "Accept"))
        await settle()

        #expect(keys(in: model) == ["ArtistId", "ArtistId", "Name"])
    }

    // MARK: - Clipboard

    @Test("Copy Visible writes the lines on screen through the clipboard service")
    func copyVisibleWritesTheFilteredLines() throws {
        let original = ClipboardService.shared
        defer { ClipboardService.shared = original }
        let clipboard = JSONInspectorClipboard()
        ClipboardService.shared = clipboard

        let model = makeModel(gate: FetchGate())
        model.update(snapshot: Self.documentSnapshot())
        model.filterText = "teal"
        model.toggle(row: try metaRow(in: model))
        model.copyVisible()

        #expect(clipboard.texts == ["{\n  \"meta\": {…}\n}"])
    }
}
