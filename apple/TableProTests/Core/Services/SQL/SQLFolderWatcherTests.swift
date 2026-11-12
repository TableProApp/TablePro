//
//  SQLFolderWatcherTests.swift
//  TableProTests
//
//  Every event under a linked folder used to rescan it, so a `.DS_Store` write or a build tool's
//  output in a linked repository read every SQL file again.
//

import CoreServices
import Foundation
@testable import TablePro
import Testing

struct SQLFolderWatcherTests {
    private static func event(_ path: String, _ flags: Int) -> FileSystemEvent {
        FileSystemEvent(path: path, flags: FSEventStreamEventFlags(flags))
    }

    private static func file(_ path: String) -> FileSystemEvent {
        event(path, kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
    }

    @Test("A batch of only non-SQL files and repository metadata is skipped")
    func nonSQLBatchIsSkipped() {
        let batch = [
            Self.file("/repo/.DS_Store"),
            Self.file("/repo/build/output.log"),
            Self.file("/repo/queries/.revenue.sql.swp"),
            Self.file("/repo/.git/index"),
            Self.event("/repo/.git/refs/heads", kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated),
        ]

        #expect(SQLFolderWatcher.shouldRescan(after: batch) == false)
    }

    @Test("A repository made or removed in the folder, or an ignore file edited, counts as a Git change")
    func gitStateChanges() {
        let created = Self.event("/repo/.git", kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)
        #expect(SQLFolderWatcher.touchesGitState([created]))
        #expect(SQLFolderWatcher.touchesGitState([Self.file("/repo/.DS_Store"), Self.file("/repo/queries/.gitignore")]))
        #expect(!SQLFolderWatcher.touchesGitState([Self.file("/repo/.git/index"), Self.file("/repo/.DS_Store")]))
    }

    @Test("A batch holding a SQL file is kept, whatever the case of its extension")
    func sqlFileIsKept() {
        #expect(SQLFolderWatcher.shouldRescan(after: [Self.file("/repo/notes.txt"), Self.file("/repo/q/Revenue.SQL")]))
        #expect(SQLFolderWatcher.shouldRescan(after: [Self.file("/repo/q/daily.pgsql")]))
    }

    @Test("A directory event is kept, a renamed directory included")
    func directoryEventIsKept() {
        let created = Self.event("/repo/queries", kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)
        let renamed = Self.event("/repo/reports", kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)

        #expect(SQLFolderWatcher.shouldRescan(after: [Self.file("/repo/.DS_Store"), created]))
        #expect(SQLFolderWatcher.shouldRescan(after: [renamed]))
    }

    @Test("A batch whose paths no longer say what changed is kept")
    func coalescedBatchIsKept() {
        let flags = [
            kFSEventStreamEventFlagMustScanSubDirs,
            kFSEventStreamEventFlagRootChanged,
            kFSEventStreamEventFlagUserDropped,
            kFSEventStreamEventFlagKernelDropped,
            kFSEventStreamEventFlagEventIdsWrapped,
        ]
        for flag in flags {
            let batch = [Self.event("/repo/build.log", kFSEventStreamEventFlagItemIsFile | flag)]
            #expect(SQLFolderWatcher.shouldRescan(after: batch), "flag \(flag)")
        }
    }
}
