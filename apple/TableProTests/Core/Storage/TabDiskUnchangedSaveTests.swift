import Foundation
@testable import TablePro
import Testing

struct TabDiskUnchangedSaveTests {
    private let tabStateDirectory = AppStorageEnvironment.shared.applicationSupportRoot
        .appendingPathComponent("TablePro", isDirectory: true)
        .appendingPathComponent("TabState", isDirectory: true)

    private func stateURL(_ connectionId: UUID) -> URL {
        tabStateDirectory.appendingPathComponent("\(connectionId.uuidString).json")
    }

    private func sidecarURL(_ connectionId: UUID, tabId: UUID) -> URL {
        TabQueryOverflowStore.directory(inside: tabStateDirectory)
            .appendingPathComponent("\(connectionId.uuidString)_\(tabId.uuidString).sql")
    }

    private func fileNumber(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    private func tab(id: UUID = UUID(), title: String, query: String) -> PersistedTab {
        PersistedTab(
            id: id,
            title: title,
            query: query,
            tabType: .query,
            tableName: nil,
            columnWidths: ["b": 120, "a": 80, "c": 64]
        )
    }

    @discardableResult
    private func save(_ tabs: [PersistedTab], connectionId: UUID, selected: UUID? = nil) async throws -> Bool {
        try await TabDiskActor.shared.save(
            connectionId: connectionId,
            tabs: tabs,
            selectedTabId: selected ?? tabs.first?.id,
            writeToken: TabDiskActor.issueWriteToken(for: connectionId)
        )
    }

    @Test("A save that changes nothing leaves the tab file in place, and a change replaces it")
    func unchangedSaveKeepsTheFile() async throws {
        let connectionId = UUID()
        defer { TabDiskActor.clearSync(connectionId: connectionId) }
        let tabs = [tab(title: "One", query: "SELECT 1"), tab(title: "Two", query: "SELECT 2")]

        try await save(tabs, connectionId: connectionId)
        let written = try fileNumber(stateURL(connectionId))
        try await save(tabs, connectionId: connectionId)
        #expect(try fileNumber(stateURL(connectionId)) == written)

        try await save(tabs, connectionId: connectionId, selected: tabs[1].id)
        #expect(try fileNumber(stateURL(connectionId)) != written)
        let loaded = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(loaded?.selectedTabId == tabs[1].id)
    }

    @Test("A tab file removed behind the store is written again by an unchanged save")
    func removedFileIsWrittenAgain() async throws {
        let connectionId = UUID()
        defer { TabDiskActor.clearSync(connectionId: connectionId) }
        let tabs = [tab(title: "One", query: "SELECT 1")]

        try await save(tabs, connectionId: connectionId)
        try FileManager.default.removeItem(at: stateURL(connectionId))
        try await save(tabs, connectionId: connectionId)

        let loaded = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(loaded?.tabs.map(\.title) == ["One"])
    }

    @Test("A tab file a load found unreadable is written again by the next unchanged save")
    func unreadableFileIsRepairedBySave() async throws {
        let connectionId = UUID()
        defer { TabDiskActor.clearSync(connectionId: connectionId) }
        let tabs = [tab(title: "One", query: "SELECT 1")]

        try await save(tabs, connectionId: connectionId)
        try Data("{".utf8).write(to: stateURL(connectionId))
        #expect(await TabDiskActor.shared.load(connectionId: connectionId) == nil)
        try await save(tabs, connectionId: connectionId)

        let loaded = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(loaded?.tabs.map(\.title) == ["One"])
    }

    @Test("An unchanged oversized query keeps its sidecar, and an edited one is rewritten")
    func sidecarIsRewrittenOnlyWhenTheQueryChanges() async throws {
        let connectionId = UUID()
        defer { TabDiskActor.clearSync(connectionId: connectionId) }
        let tabId = UUID()
        let large = String(repeating: "x", count: TabQueryContent.maxPersistableQuerySize + 1)

        try await save([tab(id: tabId, title: "Dump", query: large)], connectionId: connectionId)
        let sidecar = sidecarURL(connectionId, tabId: tabId)
        let written = try fileNumber(sidecar)
        try await save([tab(id: tabId, title: "Dump", query: large)], connectionId: connectionId)
        #expect(try fileNumber(sidecar) == written)

        let edited = large + "y"
        try await save([tab(id: tabId, title: "Dump", query: edited)], connectionId: connectionId)
        #expect(try fileNumber(sidecar) != written)
        let loaded = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(loaded?.tabs.first?.query == edited)
    }

    @Test("A sidecar removed behind the store is written again by an unchanged save")
    func removedSidecarIsWrittenAgain() async throws {
        let connectionId = UUID()
        defer { TabDiskActor.clearSync(connectionId: connectionId) }
        let tabId = UUID()
        let large = String(repeating: "z", count: TabQueryContent.maxPersistableQuerySize + 1)

        try await save([tab(id: tabId, title: "Dump", query: large)], connectionId: connectionId)
        try FileManager.default.removeItem(at: sidecarURL(connectionId, tabId: tabId))
        try await save([tab(id: tabId, title: "Dump", query: large)], connectionId: connectionId)

        let loaded = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(loaded?.tabs.first?.query == large)
    }

    @Test("A closed tab's sidecar is removed even though the other sidecars did not change")
    func closedTabSidecarIsPruned() async throws {
        let connectionId = UUID()
        defer { TabDiskActor.clearSync(connectionId: connectionId) }
        let kept = UUID()
        let closed = UUID()
        let large = String(repeating: "q", count: TabQueryContent.maxPersistableQuerySize + 1)

        try await save(
            [tab(id: kept, title: "Kept", query: large), tab(id: closed, title: "Closed", query: large)],
            connectionId: connectionId
        )
        try await save([tab(id: kept, title: "Kept", query: large)], connectionId: connectionId)

        #expect(FileManager.default.fileExists(atPath: sidecarURL(connectionId, tabId: kept).path))
        #expect(!FileManager.default.fileExists(atPath: sidecarURL(connectionId, tabId: closed).path))
    }

    @Test("After a clear, saving the same tabs writes them again")
    func saveAfterClearWrites() async throws {
        let connectionId = UUID()
        defer { TabDiskActor.clearSync(connectionId: connectionId) }
        let tabs = [tab(title: "One", query: "SELECT 1")]

        try await save(tabs, connectionId: connectionId)
        TabDiskActor.clearSync(connectionId: connectionId)
        try await save(tabs, connectionId: connectionId)

        let loaded = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(loaded?.tabs.map(\.title) == ["One"])
    }

    @Test("The quit-time save skips an unchanged state too, and still writes a change")
    func syncSaveSkipsUnchangedState() async throws {
        let connectionId = UUID()
        defer { TabDiskActor.clearSync(connectionId: connectionId) }
        let tabs = [tab(title: "One", query: "SELECT 1")]

        try await save(tabs, connectionId: connectionId)
        let written = try fileNumber(stateURL(connectionId))
        TabDiskActor.saveSync(connectionId: connectionId, tabs: tabs, selectedTabId: tabs.first?.id)
        #expect(try fileNumber(stateURL(connectionId)) == written)

        let renamed = [tab(id: tabs[0].id, title: "Renamed", query: "SELECT 1")]
        TabDiskActor.saveSync(connectionId: connectionId, tabs: renamed, selectedTabId: renamed.first?.id)
        let loaded = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(loaded?.tabs.map(\.title) == ["Renamed"])
    }
}
