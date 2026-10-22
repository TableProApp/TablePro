//
//  AttachedDatabaseListModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct AttachedDatabaseListModelTests {
    private func model(_ databases: [AttachedDatabase]) -> AttachedDatabaseListModel {
        AttachedDatabaseListModel(encoded: AttachedDatabaseList.encode(databases))
    }

    @Test("Reads the stored list into rows in order, and an unreadable value says so")
    func readsStoredList() {
        let list = model([
            AttachedDatabase(name: "auth", path: "/data/auth.db"),
            AttachedDatabase(name: "audit", path: "/data/audit.db")
        ])
        #expect(list.rows.map { $0.name } == ["auth", "audit"])
        #expect(!list.isUnreadable)
        #expect(AttachedDatabaseListModel(encoded: "not json").isUnreadable)
    }

    @Test("An added file is named after it, a taken name gets a number, and a listed file is selected")
    func addsNamedRows() {
        var list = model([AttachedDatabase(name: "auth", path: "/data/auth.db")])
        let existing = list.rows[0].id
        let selection = list.add(paths: ["/data/auth.db", "/backup/auth.sqlite", "/data/main.db"])
        #expect(list.rows.map { $0.name } == ["auth", "auth_2", "main_2"])
        #expect(list.rows.map { $0.path } == ["/data/auth.db", "/backup/auth.sqlite", "/data/main.db"])
        #expect(selection.contains(existing))
        #expect(selection.count == 3)
    }

    @Test("A renamed row is what gets stored, and the stored value round-trips")
    func renameIsStored() throws {
        var list = model([AttachedDatabase(name: "auth", path: "/data/auth.db")])
        list.setName("accounts", for: list.rows[0].id)
        let stored = try AttachedDatabaseList.decode(list.encoded)
        #expect(stored == [AttachedDatabase(name: "accounts", path: "/data/auth.db")])
        #expect(list.matches(encoded: list.encoded))
    }

    @Test("A row with no file is not stored")
    func emptyPathIsNotStored() {
        var list = model([AttachedDatabase(name: "auth", path: "/data/auth.db")])
        list.setPath("  ", for: list.rows[0].id)
        #expect(list.databases.isEmpty)
        #expect(list.encoded.isEmpty)
    }

    @Test("Removing selects the row that takes the first removed place, and moving reorders")
    func removeAndMove() {
        var list = model([
            AttachedDatabase(name: "a", path: "/a.db"),
            AttachedDatabase(name: "b", path: "/b.db"),
            AttachedDatabase(name: "c", path: "/c.db")
        ])
        list.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(list.rows.map { $0.name } == ["c", "a", "b"])
        let next = list.remove([list.rows[1].id])
        #expect(list.rows.map { $0.name } == ["c", "b"])
        #expect(next == [list.rows[1].id])
    }

    @Test("A path that is not full, or names no file, is flagged; an existing file is not")
    func fileIssues() throws {
        #expect(AttachedDatabaseFileIssue.issue(forPath: "data/auth.db") == .notFullPath)
        #expect(AttachedDatabaseFileIssue.issue(forPath: "/nonexistent-\(UUID().uuidString).db") == .missing)
        #expect(AttachedDatabaseFileIssue.issue(forPath: "") == nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("attached-\(UUID().uuidString).db")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(AttachedDatabaseFileIssue.issue(forPath: file.path) == nil)
    }
}
