import Foundation
@testable import TableProMobile
import TableProSyncTransport
import Testing

@MainActor
@Suite("Connection list state")
struct ConnectionListStateTests {
    private func state(
        loadStatus: LoadStatus = .ready,
        hasItems: Bool = false,
        activeProject: Bool = false,
        syncEnabled: Bool = false,
        status: SyncStatus = .idle,
        firstSyncDone: Bool = false
    ) -> ConnectionListState {
        ConnectionListState.resolve(
            loadStatus: loadStatus,
            hasLibraryItems: hasItems,
            hasActiveProject: activeProject,
            isSyncEnabled: syncEnabled,
            syncStatus: status,
            hasCompletedFirstSync: firstSyncDone
        )
    }

    @Test("A library that failed to load is never shown as empty")
    func failedLoad() {
        #expect(state(loadStatus: .failed) == .failed)
        #expect(state(loadStatus: .failed, hasItems: true) == .failed)
    }

    @Test("An empty library with sync off offers the local actions")
    func emptyLocal() {
        #expect(state() == .empty(syncsWithICloud: false))
    }

    @Test("An empty library with an active project shows the project's list, not the first run")
    func emptyLibraryInsideProject() {
        #expect(state(activeProject: true) == .content(syncProblem: nil))
        #expect(state(activeProject: true, syncEnabled: true, status: .syncing) == .content(syncProblem: nil))
        #expect(
            state(activeProject: true, syncEnabled: true, status: .error(.offline)) == .content(syncProblem: .offline)
        )
    }

    @Test("A library that is still loading or failed to load ignores the active project")
    func loadStatusWinsOverProject() {
        #expect(state(loadStatus: .loading, activeProject: true) == .loading)
        #expect(state(loadStatus: .failed, activeProject: true) == .failed)
    }

    @Test("The first iCloud pull shows progress instead of an empty list")
    func firstPull() {
        #expect(state(syncEnabled: true, status: .syncing) == .checkingICloud)
    }

    @Test("A later sync over an empty library does not look like a first pull")
    func laterSync() {
        #expect(state(syncEnabled: true, status: .syncing, firstSyncDone: true) == .empty(syncsWithICloud: true))
    }

    @Test("iCloud trouble before anything arrived is said, not hidden")
    func unavailable() {
        #expect(state(syncEnabled: true, status: .error(.blocked(.signedOut))) == .iCloudUnavailable(.blocked(.signedOut)))
    }

    @Test("Full storage before the first sync is reported as itself, not as an account problem")
    func storageFullBeforeFirstSync() {
        #expect(state(syncEnabled: true, status: .error(.blocked(.storageFull))) == .iCloudUnavailable(.blocked(.storageFull)))
    }

    @Test("A sync problem over a loaded library keeps the rows and reports it")
    func problemWithContent() {
        #expect(state(hasItems: true, syncEnabled: true, status: .error(.offline)) == .content(syncProblem: .offline))
    }

    @Test("A stale sync error is ignored once sync is off")
    func errorIgnoredWhenOff() {
        #expect(state(hasItems: true, status: .error(.offline)) == .content(syncProblem: nil))
    }
}
