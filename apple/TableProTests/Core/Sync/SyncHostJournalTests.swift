import Combine
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncHostJournalTests {
    @Test("A write names the core's kind and each id once, in the order written")
    func aWriteNamesTheKindAndEachIdOnce() {
        let journal = SyncJournalRecorder()

        journal.journal.recorded(.favorite, written: ["B", "A", "B"], deleted: ["C", "C"])

        #expect(journal.changes == [SyncHostChange(kind: "saved_query", written: ["B", "A"], deleted: ["C"])])
    }

    @Test("An id a write both removed and wrote back counts as written")
    func anIdWrittenBackCountsAsWritten() {
        let journal = SyncJournalRecorder()

        journal.journal.recorded(.tableFolderItem, written: ["moved"], deleted: ["moved", "gone"])

        #expect(journal.changes == [SyncHostChange(kind: "table_folder_item", written: ["moved"], deleted: ["gone"])])
    }

    @Test("Writes before anyone listens reach the first listener, and later ones go to it as they happen")
    func writesBeforeTheFirstListenerWait() {
        let journal = SyncHostJournal()
        journal.recorded(.connection, written: ["A"])
        journal.recorded(.connection, deleted: ["A"])
        var received: [SyncHostChange] = []

        let listening = journal.listen { received.append($0) }
        journal.recorded(.group, written: ["G"])

        #expect(received == [
            SyncHostChange(kind: "connection", written: [], deleted: ["A"]),
            SyncHostChange(kind: "group", written: ["G"], deleted: [])
        ])
        listening.cancel()
    }

    @Test("A write that changed nothing tells nobody")
    func anEmptyWriteIsSilent() {
        let journal = SyncJournalRecorder()

        journal.journal.recorded(.connection)
        journal.journal.recorded(.group, written: [], deleted: [])

        #expect(journal.changes.isEmpty)
    }

    @Test("Every record type iCloud carries maps to the core kind of the same CloudKit record type")
    func everyRecordTypeHasItsCoreKind() {
        let kinds = Dictionary(uniqueKeysWithValues: SyncRecordType.allCases.map { ($0, $0.coreKind) })

        #expect(kinds == [
            .connection: "connection",
            .group: "group",
            .tag: "tag",
            .settings: "macos_settings",
            .favorite: "saved_query",
            .favoriteFolder: "saved_query_folder",
            .tableFavorite: "favourite_table",
            .favoriteDatabase: "favourite_database",
            .sshProfile: "ssh_profile",
            .credentialProfile: "credential_profile",
            .tableFolder: "table_folder",
            .tableFolderItem: "table_folder_item",
            .project: "connection_project"
        ])
    }

    @Test("Queued changes keep one entry per kind, each id under the last thing done to it")
    func theQueueKeepsTheLastWordPerId() {
        var queue = SyncHostChangeQueue()

        queue.append(SyncHostChange(kind: "connection", written: ["A", "B"], deleted: ["C"]))
        queue.append(SyncHostChange(kind: "group", written: ["G"], deleted: []))
        queue.append(SyncHostChange(kind: "connection", written: ["C"], deleted: ["A"]))

        #expect(queue.changes == [
            SyncHostChange(kind: "connection", written: ["B", "C"], deleted: ["A"]),
            SyncHostChange(kind: "group", written: ["G"], deleted: [])
        ])
    }

    @Test("Changes put back go ahead of those queued since, so a later write still wins")
    func putBackChangesGoFirst() {
        var queue = SyncHostChangeQueue()
        queue.append(SyncHostChange(kind: "connection", written: ["A"], deleted: []))

        queue.putBack([SyncHostChange(kind: "connection", written: [], deleted: ["A", "B"])])

        #expect(queue.takeAll() == [SyncHostChange(kind: "connection", written: ["A"], deleted: ["B"])])
        #expect(queue.isEmpty)
    }
}
