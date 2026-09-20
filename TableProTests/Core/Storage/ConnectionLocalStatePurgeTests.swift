//
//  ConnectionLocalStatePurgeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// The stores a deleted connection leaves behind that can only be reached with `await`, and the
/// drift guard over the three sites that delete one.
@Suite("Connection local state purge")
struct ConnectionLocalStatePurgeTests {
    private func makeHistory() -> (QueryHistoryManager, QueryHistoryStorage) {
        let storage = QueryHistoryStorage(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-tests")
                .appendingPathComponent("purge_\(UUID().uuidString).db"),
            removeDatabaseOnDeinit: true
        )
        return (QueryHistoryManager(storage: storage, isCapturePaused: { false }), storage)
    }

    private func planIdentity(connectionId: UUID, subjectSQL: String) -> QueryPlanIdentity {
        QueryPlanIdentity(
            fingerprintHash: SQLQueryFingerprint.hash(subjectSQL, databaseType: .postgresql),
            scope: QueryPlanScope(
                connectionId: connectionId,
                databaseType: .postgresql,
                databaseName: "shop",
                schemaName: nil
            ),
            variantKey: .declared("explain"),
            format: .postgresJson
        )
    }

    private func entry(connectionId: UUID, query: String, id: UUID = UUID()) -> QueryHistoryEntry {
        QueryHistoryEntry(
            id: id,
            query: query,
            connectionId: connectionId,
            databaseName: "shop",
            databaseType: .postgresql,
            schemaName: nil,
            source: .editor,
            executionTime: 0.1,
            rowCount: 1,
            wasSuccessful: true
        )
    }

    private func recordedQueries(
        _ storage: QueryHistoryStorage,
        connectionId: UUID
    ) async -> [String] {
        await storage.fetch(
            QueryHistoryFilter(scope: .connection(connectionId)),
            after: nil,
            limit: 200
        ).entries.map(\.query)
    }

    @Test("Purging a connection clears its query history")
    func purgeClearsQueryHistory() async {
        let (manager, storage) = makeHistory()
        let deleted = UUID()
        _ = await storage.record(entry(connectionId: deleted, query: "SELECT secret FROM billing"))

        await ConnectionLocalState.purgeAsyncStores([deleted], queryHistory: manager)

        #expect(await recordedQueries(storage, connectionId: deleted).isEmpty)
    }

    @Test("Purging a connection leaves another connection's history alone")
    func purgeIsScopedToItsConnection() async {
        let (manager, storage) = makeHistory()
        let deleted = UUID()
        let kept = UUID()
        _ = await storage.record(entry(connectionId: deleted, query: "SELECT secret FROM billing"))
        _ = await storage.record(entry(connectionId: kept, query: "SELECT 1"))

        await ConnectionLocalState.purgeAsyncStores([deleted], queryHistory: manager)

        #expect(await recordedQueries(storage, connectionId: deleted).isEmpty)
        #expect(await recordedQueries(storage, connectionId: kept) == ["SELECT 1"])
    }

    @Test("Purging several connections clears every one of them")
    func purgeClearsEveryConnection() async {
        let (manager, storage) = makeHistory()
        let first = UUID()
        let second = UUID()
        _ = await storage.record(entry(connectionId: first, query: "SELECT 1"))
        _ = await storage.record(entry(connectionId: second, query: "SELECT 2"))

        await ConnectionLocalState.purgeAsyncStores([first, second], queryHistory: manager)

        #expect(await recordedQueries(storage, connectionId: first).isEmpty)
        #expect(await recordedQueries(storage, connectionId: second).isEmpty)
    }

    /// A filtered clear deletes from `history` alone, and both snapshot tables keep their own copy
    /// of the statement: `plan_snapshots.subject_sql` and `raw_plan`. Their `history_id` is
    /// `ON DELETE SET NULL`, so the plan outlived the history row it came from.
    @Test("Purging a connection takes its saved query plans with the history")
    func purgeClearsPlanSnapshots() async {
        let (manager, storage) = makeHistory()
        let deleted = UUID()
        let identity = planIdentity(connectionId: deleted, subjectSQL: "SELECT card FROM billing")
        let historyId = UUID()
        _ = await storage.record(
            entry(connectionId: deleted, query: "EXPLAIN SELECT card FROM billing", id: historyId)
        )
        _ = await storage.recordPlanSnapshot(
            QueryPlanCapture(
                id: UUID(),
                identity: identity,
                subjectSQL: "SELECT card FROM billing",
                rawPlan: "Seq Scan on billing",
                executionTime: 0.1,
                capturedAt: Date(timeIntervalSince1970: 1),
                historyId: historyId
            )
        )
        #expect(!(await storage.planSnapshots(matching: identity, excluding: nil, limit: 10)).isEmpty)

        await ConnectionLocalState.purgeAsyncStores([deleted], queryHistory: manager)

        #expect((await storage.planSnapshots(matching: identity, excluding: nil, limit: 10)).isEmpty)
    }

    @Test("Purging a connection leaves another connection's saved plans alone")
    func purgeLeavesOtherConnectionsPlansAlone() async {
        let (manager, storage) = makeHistory()
        let deleted = UUID()
        let kept = UUID()
        let keptIdentity = planIdentity(connectionId: kept, subjectSQL: "SELECT 1")
        let historyId = UUID()
        _ = await storage.record(entry(connectionId: kept, query: "EXPLAIN SELECT 1", id: historyId))
        _ = await storage.recordPlanSnapshot(
            QueryPlanCapture(
                id: UUID(),
                identity: keptIdentity,
                subjectSQL: "SELECT 1",
                rawPlan: "Result",
                executionTime: 0.1,
                capturedAt: Date(timeIntervalSince1970: 1),
                historyId: historyId
            )
        )

        await ConnectionLocalState.purgeAsyncStores([deleted], queryHistory: manager)

        #expect(!(await storage.planSnapshots(matching: keptIdentity, excluding: nil, limit: 10)).isEmpty)
    }

    /// `ConnectionLocalState` exists because this list used to be written out at each delete site,
    /// and they drifted: the query history clear reached the two local sites and never the remote
    /// one. Anything reaching these stores itself is that drift starting again.
    ///
    /// Scans the whole app rather than the two files that regressed, because a delete site added in
    /// a third one is exactly what a two-file list would miss. Comments are stripped first: this
    /// codebase explains its routing decisions in `///` blocks, and a block naming the store it
    /// deliberately does not call would otherwise fail the suite with no defect present. A file
    /// that declares the method is exempt, so a type forwarding to its own storage is not a site.
    @Test("Only ConnectionLocalState clears a deleted connection's async stores")
    func onlyConnectionLocalStateClearsAsyncStores() throws {
        let root = try Self.repoRoot().appendingPathComponent("TablePro", isDirectory: true)
        let calls = ["removeFavoritesAndFolders(for:", "deleteEverything(forConnection:"]

        var offenders: [String] = []
        for url in try Self.swiftSources(under: root)
        where url.lastPathComponent != "ConnectionLocalState.swift" {
            let code = Self.strippingComments(try String(contentsOf: url, encoding: .utf8))
            for call in calls where code.contains(call) {
                let name = call.prefix { $0 != "(" }
                guard !code.contains("func \(name)(") else { continue }
                offenders.append("\(url.lastPathComponent) calls \(call)")
            }
        }

        #expect(
            offenders.isEmpty,
            "A deleted connection's async stores are cleared through ConnectionLocalState.purge: \(offenders.sorted())"
        )
    }

    private static func swiftSources(under directory: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Line comments only. A `/* */` block holding one of these names would slip through, which is
    /// a trade for not hand-rolling a Swift lexer in a guard test.
    private static func strippingComments(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
