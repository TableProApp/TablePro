//
//  LinkedFolderCommitDraftTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct LinkedFolderCommitDraftTests {
    private let modified = GitFileStatus(staged: .unmodified, unstaged: .modified)
    private let conflicted = GitFileStatus(staged: .unmerged, unstaged: .unmerged, isUnmergedEntry: true)

    private func record(_ path: String, _ status: GitFileStatus, from originalPath: String? = nil) -> GitStatusRecord {
        GitStatusRecord(path: path, originalPath: originalPath, status: status)
    }

    @Test("From the folder every committable file under it is checked, sorted by name, and nothing outside it is listed")
    func folderChecksEverything() {
        let draft = LinkedFolderCommitDraft(
            records: [
                record("sql/b.sql", modified),
                record("sql/a 2.sql", .untracked),
                record("sql/a 10.sql", modified),
                record("app/main.swift", modified),
            ],
            prefix: "sql/"
        )

        #expect(draft.entries.map(\.folderRelativePath) == ["a 2.sql", "a 10.sql", "b.sql"])
        #expect(Set(draft.commitPaths) == ["sql/a 2.sql", "sql/a 10.sql", "sql/b.sql"])
    }

    @Test("From a file only that file is checked")
    func fileChecksItself() {
        let draft = LinkedFolderCommitDraft(
            records: [record("sql/a.sql", modified), record("sql/b.sql", modified)],
            prefix: "sql/",
            preselecting: "b.sql"
        )

        #expect(draft.commitPaths == ["sql/b.sql"])
    }

    @Test("A conflicted file is listed but can never be checked")
    func conflictedFileStaysOut() throws {
        var draft = LinkedFolderCommitDraft(
            records: [record("sql/a.sql", conflicted), record("sql/b.sql", modified)],
            prefix: "sql/",
            preselecting: "a.sql"
        )
        let conflictedEntry = try #require(draft.entries.first { $0.path == "sql/a.sql" })

        #expect(draft.entries.count == 2)
        #expect(draft.commitPaths == ["sql/b.sql"])
        draft.setChecked(conflictedEntry, true)
        #expect(!draft.isChecked(conflictedEntry))
        #expect(draft.commitPaths == ["sql/b.sql"])
    }

    @Test("Commit needs a checked file and a message that is more than whitespace")
    func commitNeedsFilesAndMessage() throws {
        var draft = LinkedFolderCommitDraft(records: [record("sql/a.sql", modified)], prefix: "sql/")
        let entry = try #require(draft.entries.first)

        #expect(!draft.canCommit)
        draft.message = " \n "
        #expect(!draft.canCommit)
        draft.message = "Fix the report"
        #expect(draft.canCommit)
        draft.setChecked(entry, false)
        #expect(!draft.canCommit)
    }

    @Test("A staged rename inside the folder commits its old path too, one from outside or listed again does not")
    func renameOrigins() throws {
        let renamed = GitFileStatus(staged: .renamed, unstaged: .unmodified)
        var draft = LinkedFolderCommitDraft(
            records: [
                record("sql/new.sql", renamed, from: "sql/old.sql"),
                record("sql/moved.sql", renamed, from: "elsewhere/moved.sql"),
                record("sql/b2.sql", renamed, from: "sql/b.sql"),
                record("sql/b.sql", .untracked),
            ],
            prefix: "sql/"
        )
        let recreated = try #require(draft.entries.first { $0.path == "sql/b.sql" })
        draft.setChecked(recreated, false)

        #expect(Set(draft.commitPaths) == ["sql/new.sql", "sql/old.sql", "sql/moved.sql", "sql/b2.sql"])
        #expect(draft.entries.first { $0.path == "sql/new.sql" }?.comparedPath == "sql/old.sql")
    }

    @Test("Only checked untracked files are added before the commit")
    func untrackedPathsAreAdded() {
        let draft = LinkedFolderCommitDraft(
            records: [
                record("sql/a.sql", modified),
                record("sql/n.sql", .untracked),
                record("sql/d.sql", GitFileStatus(staged: .deleted, unstaged: .unmodified)),
            ],
            prefix: "sql/"
        )

        #expect(draft.untrackedPaths == ["sql/n.sql"])
    }

    @Test("An index deletion and an untracked file at one path are one entry")
    func duplicatePathIsOneEntry() {
        let draft = LinkedFolderCommitDraft(
            records: [
                record("sql/a.sql", .untracked),
                record("sql/a.sql", GitFileStatus(staged: .deleted, unstaged: .unmodified)),
            ],
            prefix: "sql/"
        )

        #expect(draft.entries.count == 1)
        #expect(draft.entries.first?.status.isUntracked == false)
    }

    @Test("A file with a NUL byte and no byte order mark is binary, UTF-16 text is not")
    func binaryDetection() throws {
        #expect(LinkedFolderCommitDiffLoader.isBinary(Data([0x89, 0x50, 0x00, 0x47])))
        #expect(!LinkedFolderCommitDiffLoader.isBinary(Data("SELECT 1;".utf8)))
        let utf16 = try #require("SELECT 1;".data(using: .utf16))
        #expect(!LinkedFolderCommitDiffLoader.isBinary(utf16))
    }
}
