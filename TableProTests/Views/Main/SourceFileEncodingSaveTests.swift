//
//  SourceFileEncodingSaveTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor @Suite("Source file encoding on save")
struct SourceFileEncodingSaveTests {
    private final class ReportedErrors {
        var entries: [(title: String, message: String)] = []
    }

    private struct Harness {
        let coordinator: MainContentCoordinator
        let actions: MainContentCommandActions
        let reported: ReportedErrors
    }

    private static let unrepresentable = "SELECT '\u{1F600}';\n"

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
        let reported = ReportedErrors()
        coordinator.presentError = { title, message, _ in reported.entries.append((title, message)) }
        return Harness(coordinator: coordinator, actions: actions, reported: reported)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-file-encoding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func openFileTab(
        _ fixture: EncodedSQLFileFixture,
        at url: URL,
        editedTo query: String,
        in coordinator: MainContentCoordinator
    ) throws -> UUID {
        try fixture.write(fixture.original, to: url)
        let loaded = try #require(FileTextLoader.load(url))
        #expect(loaded.content == fixture.original)
        coordinator.tabManager.addTab(
            initialQuery: loaded.content,
            sourceFileURL: url,
            sourceFileStamp: loaded.stamp,
            sourceFileEncoding: loaded.textEncoding
        )
        let id = try #require(coordinator.tabManager.selectedTabId)
        coordinator.tabManager.mutate(tabId: id) { $0.content.query = query }
        return id
    }

    private func tab(_ id: UUID, in coordinator: MainContentCoordinator) -> QueryTab? {
        coordinator.tabManager.tabs.first { $0.id == id }
    }

    private func expectSaved(
        _ fixture: EncodedSQLFileFixture,
        at url: URL,
        tab id: UUID,
        in harness: Harness
    ) throws {
        let expected = try #require(fixture.bytes(of: fixture.edited))
        #expect(try Data(contentsOf: url) == expected, "\(fixture)")
        #expect(EncodedSQLFileFixture.attributeValue(of: url) == fixture.attributeValue, "\(fixture)")
        let reloaded = try #require(FileTextLoader.load(url))
        #expect(reloaded.content == fixture.edited, "\(fixture)")
        #expect(reloaded.encoding == fixture.reportedEncoding, "\(fixture)")
        #expect(tab(id, in: harness.coordinator)?.content.isFileDirty == false, "\(fixture)")
        #expect(harness.reported.entries.isEmpty, "\(fixture)")
    }

    @Test(
        "Cmd+S writes a file back in the encoding it was read in",
        arguments: EncodedSQLFileFixture.allCases
    )
    func commandSaveKeepsTheEncoding(fixture: EncodedSQLFileFixture) async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let id = try openFileTab(fixture, at: url, editedTo: fixture.edited, in: harness.coordinator)

        let saved = await harness.actions.saveSelectedFileAwaiting()

        #expect(saved)
        try expectSaved(fixture, at: url, tab: id, in: harness)
    }

    @Test(
        "A batch save writes each file back in the encoding it was read in",
        arguments: EncodedSQLFileFixture.allCases
    )
    func batchSaveKeepsTheEncoding(fixture: EncodedSQLFileFixture) async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let id = try openFileTab(fixture, at: url, editedTo: fixture.edited, in: harness.coordinator)
        let dirty = try #require(tab(id, in: harness.coordinator))

        let saved = await harness.actions.saveFiles([(tab: dirty, url: url)]).contains(id)

        #expect(saved)
        try expectSaved(fixture, at: url, tab: id, in: harness)
    }

    @Test("A second save keeps the encoding the first one wrote")
    func repeatedSavesKeepTheEncoding() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let fixture = EncodedSQLFileFixture.shiftJISByAttribute
        let id = try openFileTab(fixture, at: url, editedTo: fixture.original + "--", in: harness.coordinator)

        #expect(await harness.actions.saveSelectedFileAwaiting())
        harness.coordinator.tabManager.mutate(tabId: id) { $0.content.query = fixture.edited }
        #expect(await harness.actions.saveSelectedFileAwaiting())

        try expectSaved(fixture, at: url, tab: id, in: harness)
    }

    @Test("A tab that never learned its file's encoding keeps the one on disk")
    func unknownEncodingKeepsTheFilesOwn() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        let fixture = EncodedSQLFileFixture.windowsCyrillicByAttribute
        try fixture.write(fixture.original, to: url)
        let loaded = try #require(FileTextLoader.load(url))
        harness.coordinator.tabManager.addTab(
            initialQuery: loaded.content,
            sourceFileURL: url,
            sourceFileStamp: loaded.stamp
        )
        let id = try #require(harness.coordinator.tabManager.selectedTabId)
        #expect(tab(id, in: harness.coordinator)?.content.sourceFileEncoding == nil)
        harness.coordinator.tabManager.mutate(tabId: id) { $0.content.query = fixture.edited }

        #expect(await harness.actions.saveSelectedFileAwaiting())

        try expectSaved(fixture, at: url, tab: id, in: harness)
    }

    @Test("Cmd+S refuses text the file's encoding cannot hold, names the file and why, and leaves it alone")
    func commandSaveRefusesUnrepresentableText() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("latin.sql")
        let fixture = EncodedSQLFileFixture.latin1Fallback
        let id = try openFileTab(fixture, at: url, editedTo: Self.unrepresentable, in: harness.coordinator)
        let before = try Data(contentsOf: url)

        let saved = await harness.actions.saveSelectedFileAwaiting()

        #expect(!saved)
        #expect(try Data(contentsOf: url) == before)
        #expect(tab(id, in: harness.coordinator)?.content.query == Self.unrepresentable)
        #expect(tab(id, in: harness.coordinator)?.content.isFileDirty == true)
        #expect(harness.reported.entries.map(\.title) == [String(localized: "Couldn't Save File")])
        let message = try #require(harness.reported.entries.first?.message)
        #expect(message.contains("latin.sql"))
        #expect(message.contains(String.localizedName(of: .isoLatin1)))
    }

    @Test("Save on close refuses text the file's encoding cannot hold and keeps the tab open")
    func saveOnCloseRefusesUnrepresentableText() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("japanese.sql")
        let fixture = EncodedSQLFileFixture.shiftJISByAttribute
        let id = try openFileTab(fixture, at: url, editedTo: Self.unrepresentable, in: harness.coordinator)
        let before = try Data(contentsOf: url)

        let mayClose = await harness.actions.saveSelectedTabWork()

        #expect(!mayClose)
        #expect(try Data(contentsOf: url) == before)
        #expect(EncodedSQLFileFixture.attributeValue(of: url) == fixture.attributeValue)
        #expect(tab(id, in: harness.coordinator)?.content.query == Self.unrepresentable)
        let message = try #require(harness.reported.entries.first?.message)
        #expect(message.contains("japanese.sql"))
        #expect(message.contains(String.localizedName(of: .shiftJIS)))
    }

    @Test("Save on a batch close refuses each file its encoding cannot hold in one alert and closes only what saved")
    func batchCloseRefusesUnrepresentableText() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let latinURL = folder.appendingPathComponent("latin.sql")
        let cyrillicURL = folder.appendingPathComponent("cyrillic.sql")
        let savedURL = folder.appendingPathComponent("saved.sql")
        let savedFixture = EncodedSQLFileFixture.utf16BigEndianWithByteOrderMark
        let latinID = try openFileTab(
            .latin1Fallback, at: latinURL, editedTo: Self.unrepresentable, in: harness.coordinator
        )
        let cyrillicID = try openFileTab(
            .windowsCyrillicByAttribute, at: cyrillicURL, editedTo: Self.unrepresentable, in: harness.coordinator
        )
        let savedID = try openFileTab(savedFixture, at: savedURL, editedTo: savedFixture.edited, in: harness.coordinator)
        harness.coordinator.tabManager.addTab(initialQuery: "SELECT 1")
        let victimIDs = [latinID, cyrillicID, savedID]
        #expect(harness.coordinator.tabManager.selectedTabId.map { !victimIDs.contains($0) } == true)
        let victims = victimIDs.compactMap { tab($0, in: harness.coordinator) }
        let latinBefore = try Data(contentsOf: latinURL)
        let cyrillicBefore = try Data(contentsOf: cyrillicURL)
        harness.actions.confirmSaveChanges = { _, _ in .save }

        let outcome = await harness.actions.resolveUnsavedWork(in: victims)

        #expect(outcome == .close([savedID]))
        #expect(try Data(contentsOf: latinURL) == latinBefore)
        #expect(try Data(contentsOf: cyrillicURL) == cyrillicBefore)
        #expect(EncodedSQLFileFixture.attributeValue(of: cyrillicURL) == "windows-1251;1282")
        #expect(try Data(contentsOf: savedURL) == savedFixture.bytes(of: savedFixture.edited))
        #expect(harness.reported.entries.map(\.title) == [String(localized: "Couldn't Save Files")])
        let message = try #require(harness.reported.entries.first?.message)
        #expect(message.contains("latin.sql"))
        #expect(message.contains("cyrillic.sql"))
        #expect(!message.contains("saved.sql"))
        #expect(tab(latinID, in: harness.coordinator)?.content.isFileDirty == true)
        #expect(tab(cyrillicID, in: harness.coordinator)?.content.isFileDirty == true)
    }

    @Test("A file recorded as ASCII saves any text as UTF-8 and loses the ASCII record")
    func asciiFileSavesAsUTF8() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ascii.sql")
        try "SELECT 1;\n".write(to: url, atomically: true, encoding: .ascii)
        #expect(EncodedSQLFileFixture.attributeValue(of: url) == "us-ascii;1536")
        let loaded = try #require(FileTextLoader.load(url))
        harness.coordinator.tabManager.addTab(
            initialQuery: loaded.content,
            sourceFileURL: url,
            sourceFileStamp: loaded.stamp,
            sourceFileEncoding: loaded.textEncoding
        )
        let id = try #require(harness.coordinator.tabManager.selectedTabId)
        let edited = "SELECT 'Caf\u{E9} \u{1F600}';\n"
        harness.coordinator.tabManager.mutate(tabId: id) { $0.content.query = edited }

        #expect(await harness.actions.saveSelectedFileAwaiting())

        #expect(try Data(contentsOf: url) == Data(edited.utf8))
        #expect(EncodedSQLFileFixture.attributeValue(of: url) == nil)
        #expect(FileTextLoader.load(url)?.encoding == .utf8)
        #expect(harness.reported.entries.isEmpty)
    }

    @Test("Save As writes UTF-8 and the tab saves as UTF-8 from then on")
    func saveAsConvertsToUTF8() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("japanese.sql")
        let copy = folder.appendingPathComponent("japanese-utf8.sql")
        let fixture = EncodedSQLFileFixture.shiftJISByAttribute
        let id = try openFileTab(fixture, at: url, editedTo: Self.unrepresentable, in: harness.coordinator)
        harness.actions.chooseSaveURL = { _ in copy }

        #expect(await harness.actions.saveFileAsAwaiting())

        #expect(try Data(contentsOf: copy) == Data(Self.unrepresentable.utf8))
        #expect(EncodedSQLFileFixture.attributeValue(of: copy) == nil)
        #expect(tab(id, in: harness.coordinator)?.content.sourceFileEncoding == .utf8)
        #expect(harness.reported.entries.isEmpty)

        let appended = Self.unrepresentable + "SELECT 2;\n"
        harness.coordinator.tabManager.mutate(tabId: id) { $0.content.query = appended }
        #expect(await harness.actions.saveSelectedFileAwaiting())
        #expect(try Data(contentsOf: copy) == Data(appended.utf8))
    }
}
