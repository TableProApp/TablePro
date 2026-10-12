//
//  LoadableExtensionListModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct LoadableExtensionListModelTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoadableExtensionListModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func model(_ paths: [String]) -> LoadableExtensionListModel {
        LoadableExtensionListModel(encoded: LoadableExtensionList.encode(paths.map { LoadableExtension(path: $0) }))
    }

    @Test("Reads the stored list into rows in order")
    func readsStoredList() {
        let list = model(["/a.dylib", "/b.dylib"])
        #expect(list.rows.map { $0.path } == ["/a.dylib", "/b.dylib"])
        #expect(!list.isUnreadable)
    }

    @Test("A stored value that does not decode shows as unreadable, not as silently empty")
    func flagsUnreadableValue() {
        let list = LoadableExtensionListModel(encoded: "not json")
        #expect(list.rows.isEmpty)
        #expect(list.isUnreadable)
    }

    @Test("Adding files appends them and selects them; a file already listed is selected, not repeated")
    func addsAndDeduplicates() {
        var list = model(["/a.dylib"])
        let existing = list.rows[0].id
        let selection = list.add(paths: ["/a.dylib", "/b.dylib"])
        #expect(list.rows.map { $0.path } == ["/a.dylib", "/b.dylib"])
        #expect(selection.contains(existing))
        #expect(selection.count == 2)
    }

    @Test("Removing moves the selection to the row that takes the first removed place")
    func removeKeepsSelection() {
        var list = model(["/a.dylib", "/b.dylib", "/c.dylib"])
        let next = list.remove([list.rows[1].id])
        #expect(list.rows.map { $0.path } == ["/a.dylib", "/c.dylib"])
        #expect(next == [list.rows[1].id])
    }

    @Test("Removing the last row selects the new last row, removing everything selects nothing")
    func removeAtTheEnd() {
        var list = model(["/a.dylib", "/b.dylib"])
        let first = list.rows[0].id
        let afterTail = list.remove([list.rows[1].id])
        #expect(afterTail == [first])
        let afterAll = list.remove([first])
        #expect(afterAll.isEmpty)
        #expect(list.encoded.isEmpty)
    }

    @Test("Moving reorders the load order")
    func movesRows() {
        var list = model(["/a.dylib", "/b.dylib", "/c.dylib"])
        list.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(list.rows.map { $0.path } == ["/c.dylib", "/a.dylib", "/b.dylib"])
        list.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(list.rows.map { $0.path } == ["/a.dylib", "/b.dylib", "/c.dylib"])
    }

    @Test("The stored value carries entry points and leaves out a row with no file")
    func encodesRows() throws {
        var list = model(["/a.dylib"])
        list.setEntryPoint("sqlite3_a_init", for: list.rows[0].id)
        _ = list.add(paths: ["/b.dylib"])
        list.setPath("", for: list.rows[1].id)
        let stored = try LoadableExtensionList.decode(list.encoded)
        #expect(stored == [LoadableExtension(path: "/a.dylib", entryPoint: "sqlite3_a_init")])
    }

    @Test("A row's file is checked by looking at it, never by loading it")
    func fileIssues() throws {
        let text = directory.appendingPathComponent("notes.dylib")
        try Data("not a library".utf8).write(to: text)
        let library = directory.appendingPathComponent("ls.dylib")
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: library.path)

        #expect(LoadableExtensionFileIssue.issue(forPath: "") == nil)
        #expect(LoadableExtensionFileIssue.issue(forPath: "vec0.dylib") == .notFullPath)
        #expect(LoadableExtensionFileIssue.issue(forPath: directory.appendingPathComponent("gone.dylib").path) == .missing)
        #expect(LoadableExtensionFileIssue.issue(forPath: directory.path) == .notALibrary)
        #expect(LoadableExtensionFileIssue.issue(forPath: text.path) == .notALibrary)
        #expect(LoadableExtensionFileIssue.issue(forPath: library.path) == nil)
        #expect(LoadableExtensionFileIssue.issue(forPath: String(library.path.dropLast(".dylib".count))) == .missing)
    }
}
