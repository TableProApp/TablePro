//
//  SourceFileDiskChangeHandlingTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct SourceFileDiskChangeHandlingTests {
    private struct Harness {
        let coordinator: MainContentCoordinator
        let actions: MainContentCommandActions
    }

    private func makeHarness() -> Harness {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let coordinator = SessionStateFactory.create(connection: connection, payload: nil).coordinator

        var selectedTables: Set<DatabaseTreeTableRef> = []
        var pendingTruncates: Set<DatabaseTreeTableRef> = []
        var pendingDeletes: Set<DatabaseTreeTableRef> = []
        var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]

        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectionState: coordinator.selectionState,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(
                get: { tableOperationOptions },
                set: { tableOperationOptions = $0 }
            ),
            trailingPaneState: TrailingPaneState()
        )
        actions.chooseSaveURL = { _ in
            Issue.record("Save As was not expected")
            return nil
        }
        return Harness(coordinator: coordinator, actions: actions)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-file-disk-change-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func openFileTab(
        at url: URL,
        bytes: Data = Data("SELECT 1".utf8),
        editedTo query: String,
        in coordinator: MainContentCoordinator
    ) throws -> UUID {
        try bytes.write(to: url)
        let loaded = try #require(FileTextLoader.load(url))
        coordinator.tabManager.addTab(
            initialQuery: loaded.content,
            sourceFileURL: url,
            sourceFileStamp: loaded.stamp
        )
        let id = try #require(coordinator.tabManager.selectedTabId)
        coordinator.tabManager.mutate(tabId: id) { $0.content.query = query }
        return id
    }

    private func overwriteInPlace(_ url: URL, with contents: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(contents.utf8))
        try handle.close()
    }

    private func refreshDiskChanges(of coordinator: MainContentCoordinator) async {
        coordinator.refreshSourceFileDiskChanges()
        await coordinator.sourceFileDiskChangeMonitor.waitUntilIdle()
    }

    private func tab(_ id: UUID, in coordinator: MainContentCoordinator) -> QueryTab? {
        coordinator.tabManager.tabs.first { $0.id == id }
    }

    private func isModified(_ change: SourceFileDiskChange?) -> Bool {
        guard case .modified(_)? = change else { return false }
        return true
    }

    // MARK: - Detection

    @Test("A tab whose file was deleted is told the file is missing")
    func refreshMarksADeletedFileMissing() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 1", in: harness.coordinator)

        try FileManager.default.removeItem(at: url)
        await refreshDiskChanges(of: harness.coordinator)

        #expect(tab(id, in: harness.coordinator)?.content.diskChange == .missing)
    }

    @Test("A changed-on-disk notice becomes the missing notice when the file is then deleted")
    func refreshTurnsAModifiedNoticeIntoMissing() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 1", in: harness.coordinator)

        try overwriteInPlace(url, with: "SELECT 22")
        await refreshDiskChanges(of: harness.coordinator)
        #expect(isModified(tab(id, in: harness.coordinator)?.content.diskChange))

        try FileManager.default.removeItem(at: url)
        await refreshDiskChanges(of: harness.coordinator)

        #expect(tab(id, in: harness.coordinator)?.content.diskChange == .missing)
    }

    @Test("A file put back from where it was moved clears the missing notice")
    func refreshClearsTheMarkWhenTheFileReturns() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let parked = folder.appendingPathComponent("parked.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 1", in: harness.coordinator)

        try FileManager.default.moveItem(at: url, to: parked)
        await refreshDiskChanges(of: harness.coordinator)
        #expect(tab(id, in: harness.coordinator)?.content.diskChange == .missing)

        try FileManager.default.moveItem(at: parked, to: url)
        await refreshDiskChanges(of: harness.coordinator)

        #expect(tab(id, in: harness.coordinator)?.content.diskChange == nil)
    }

    @Test("The window becoming key checks every file tab against the disk")
    func windowBecomingKeyChecksTheDisk() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 1", in: harness.coordinator)

        try FileManager.default.removeItem(at: url)
        harness.coordinator.handleWindowDidBecomeKey()
        await harness.coordinator.sourceFileDiskChangeMonitor.waitUntilIdle()

        #expect(tab(id, in: harness.coordinator)?.content.diskChange == .missing)
    }

    @Test("A dismissed notice stays closed until the file changes again")
    func dismissedNoticeStaysClosedUntilTheNextChange() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 1", in: harness.coordinator)

        try overwriteInPlace(url, with: "SELECT 22")
        await refreshDiskChanges(of: harness.coordinator)
        harness.coordinator.tabManager.mutate(tabId: id) { FileTabBaseline.dismissDiskChange(in: &$0.content) }
        await refreshDiskChanges(of: harness.coordinator)
        #expect(tab(id, in: harness.coordinator)?.content.diskChange == nil)

        try overwriteInPlace(url, with: "SELECT 333")
        await refreshDiskChanges(of: harness.coordinator)

        #expect(isModified(tab(id, in: harness.coordinator)?.content.diskChange))
    }

    @Test("A dismissed missing notice comes back when the file goes missing again")
    func dismissedMissingNoticeReturnsOnTheNextDeletion() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let parked = folder.appendingPathComponent("parked.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 1", in: harness.coordinator)

        try FileManager.default.moveItem(at: url, to: parked)
        await refreshDiskChanges(of: harness.coordinator)
        harness.coordinator.tabManager.mutate(tabId: id) { FileTabBaseline.dismissDiskChange(in: &$0.content) }
        await refreshDiskChanges(of: harness.coordinator)
        #expect(tab(id, in: harness.coordinator)?.content.diskChange == nil)

        try FileManager.default.moveItem(at: parked, to: url)
        await refreshDiskChanges(of: harness.coordinator)
        #expect(tab(id, in: harness.coordinator)?.content.dismissedDiskChange == nil)

        try FileManager.default.moveItem(at: url, to: parked)
        await refreshDiskChanges(of: harness.coordinator)

        #expect(tab(id, in: harness.coordinator)?.content.diskChange == .missing)
    }

    @Test("A check whose tab was saved while the disk was read leaves the tab alone")
    func checkOutrunByASaveIsDiscarded() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 1", in: harness.coordinator)
        let tabManager = harness.coordinator.tabManager
        let monitor = SourceFileDiskChangeMonitor(tabManager: tabManager) { urls in
            await MainActor.run {
                try? "SELECT 2".write(to: url, atomically: true, encoding: .utf8)
                tabManager.mutate(tabId: id) {
                    FileTabBaseline.recordWrite(of: "SELECT 2", to: url, as: .utf8, in: &$0.content)
                }
            }
            return urls.map { _ in nil }
        }

        monitor.refresh()
        await monitor.waitUntilIdle()

        #expect(tab(id, in: harness.coordinator)?.content.diskChange == nil)
    }

    // MARK: - Save gate

    @Test("Batch save refuses a file an older copy was restored over")
    func batchSaveRefusesAnOlderRestore() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        try "SELECT 1".write(to: url, atomically: true, encoding: .utf8)
        var restoredTab = QueryTab(title: "report", query: "SELECT 1")
        restoredTab.content.sourceFileURL = url
        FileTabBaseline.hydrate(&restoredTab)
        restoredTab.content.query = "SELECT 2"
        harness.coordinator.tabManager.adoptTab(restoredTab)

        try overwriteInPlace(url, with: "SELECT 0")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: url.path
        )
        let saved = await harness.actions.saveFiles([(tab: restoredTab, url: url)]).contains(restoredTab.id)

        #expect(!saved)
        #expect(try String(contentsOf: url, encoding: .utf8) == "SELECT 0")
        #expect(isModified(tab(restoredTab.id, in: harness.coordinator)?.content.diskChange))
    }

    @Test("Save on close stands down while the changed-on-disk conflict is open")
    func saveOnCloseStandsDownForAConflict() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 2", in: harness.coordinator)

        try overwriteInPlace(url, with: "SELECT 0")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: url.path
        )
        let mayClose = await harness.actions.saveSelectedTabWork()

        #expect(!mayClose)
        #expect(harness.coordinator.fileConflictRequest?.tabId == id)
        #expect(try String(contentsOf: url, encoding: .utf8) == "SELECT 0")
    }

    @Test("Saving a tab whose file was deleted does not recreate the file")
    func saveDoesNotRecreateADeletedFile() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 2", in: harness.coordinator)
        let dirty = try #require(tab(id, in: harness.coordinator))

        try FileManager.default.removeItem(at: url)
        let saved = await harness.actions.saveFiles([(tab: dirty, url: url)]).contains(dirty.id)

        #expect(!saved)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(tab(id, in: harness.coordinator)?.content.diskChange == .missing)
    }

    @Test("Saving a tab whose file is still in place writes it")
    func saveWritesAFileStillInPlace() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 2", in: harness.coordinator)
        let dirty = try #require(tab(id, in: harness.coordinator))

        let saved = await harness.actions.saveFiles([(tab: dirty, url: url)]).contains(dirty.id)

        #expect(saved)
        #expect(try String(contentsOf: url, encoding: .utf8) == "SELECT 2")
        #expect(tab(id, in: harness.coordinator)?.content.diskChange == nil)
    }

    @Test("Save on close for a deleted file lets the close go on once Save As writes a new file")
    func saveOnCloseProceedsAfterSaveAs() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let replacement = folder.appendingPathComponent("report copy.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 2", in: harness.coordinator)
        harness.actions.chooseSaveURL = { _ in replacement }

        try FileManager.default.removeItem(at: url)
        let mayClose = await harness.actions.saveSelectedTabWork()

        #expect(mayClose)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: replacement, encoding: .utf8) == "SELECT 2")
        #expect(tab(id, in: harness.coordinator)?.content.sourceFileURL == replacement)
        #expect(tab(id, in: harness.coordinator)?.content.isFileDirty == false)
    }

    @Test("Save on close for a deleted file stands down when Save As is cancelled")
    func saveOnCloseStandsDownWhenSaveAsIsCancelled() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let id = try openFileTab(at: url, editedTo: "SELECT 2", in: harness.coordinator)
        harness.actions.chooseSaveURL = { _ in nil }

        try FileManager.default.removeItem(at: url)
        let mayClose = await harness.actions.saveSelectedTabWork()

        #expect(!mayClose)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(tab(id, in: harness.coordinator)?.content.diskChange == .missing)
    }

    // MARK: - Trash

    @Test("A file the Trash refuses is reported and left where it was")
    func trashFailureIsReported() throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        var reportedTitles: [String] = []
        harness.coordinator.presentError = { title, _, _ in reportedTitles.append(title) }

        let folder = try makeFolder()
        let url = folder.appendingPathComponent("report.sql")
        try "SELECT 1".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let favorite = LinkedSQLFavorite(
            folderId: UUID(),
            fileURL: url,
            relativePath: "report.sql",
            name: "report",
            mtime: Date(),
            fileSize: 8
        )

        let trashed = harness.coordinator.trashLinkedFavorite(favorite)

        #expect(!trashed)
        #expect(reportedTitles == [String(localized: "Couldn't Move File to Trash")])
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
