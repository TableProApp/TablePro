//
//  QueryHistoryCaptureTests.swift
//  TableProTests
//
//  Pausing capture must stop every writer, not just the one the user was looking at.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Query history capture pause")
struct QueryHistoryCaptureTests {
    private func makeStorage() -> QueryHistoryStorage {
        QueryHistoryStorage(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-tests")
                .appendingPathComponent("capture_\(UUID().uuidString).db"),
            removeDatabaseOnDeinit: true
        )
    }

    private func makeRequest(connectionId: UUID, source: QueryHistorySource = .editor) -> QueryHistoryRecordRequest {
        QueryHistoryRecordRequest(
            query: "SELECT 1",
            connectionId: connectionId,
            databaseName: "db",
            databaseType: .postgresql,
            source: source,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
    }

    @Test("recording is dropped while capture is paused")
    func pausedCaptureRecordsNothing() async {
        let storage = makeStorage()
        let manager = QueryHistoryManager(storage: storage, isCapturePaused: { true })
        let connectionId = UUID()

        #expect(await manager.record(makeRequest(connectionId: connectionId)) == false)
        #expect(await storage.count(scope: .connection(connectionId)) == 0)
    }

    @Test("recording resumes once capture is unpaused")
    func resumedCaptureRecordsAgain() async {
        let storage = makeStorage()
        let manager = QueryHistoryManager(storage: storage, isCapturePaused: { false })
        let connectionId = UUID()

        #expect(await manager.record(makeRequest(connectionId: connectionId)))
        #expect(await storage.count(scope: .connection(connectionId)) == 1)
    }

    @Test("pausing covers every source, including MCP and app-generated statements")
    func pauseCoversEverySource() async {
        let storage = makeStorage()
        let manager = QueryHistoryManager(storage: storage, isCapturePaused: { true })
        let connectionId = UUID()

        for source in QueryHistorySource.allCases {
            #expect(await manager.record(makeRequest(connectionId: connectionId, source: source)) == false, "\(source)")
        }
        #expect(await storage.count(scope: .all) == 0)
    }

    @Test("the pause flag is device-local, so it is not part of the synced history settings")
    func pauseIsNotASyncedSetting() {
        let mirror = Mirror(reflecting: HistorySettings.default)
        let names = mirror.children.compactMap(\.label)
        #expect(names.contains("maxEntries"))
        #expect(
            names.contains(where: { $0.localizedCaseInsensitiveContains("pause") }) == false,
            "Pausing must not ride the iCloud-synced settings record"
        )
    }
}
