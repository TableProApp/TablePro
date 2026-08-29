//
//  TabPersistenceCoordinator.swift
//  TablePro
//

import Foundation
import Observation
import os

internal struct RestoreResult {
    let tabs: [QueryTab]
    let selectedTabId: UUID?
    let source: RestoreSource
    var lastActiveDatabase: String?
    var lastActiveSchema: String?

    enum RestoreSource {
        case disk
        case none
    }
}

@MainActor @Observable
internal final class TabPersistenceCoordinator {
    nonisolated internal static let logger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")
    let connectionId: UUID

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Whether this window has ever had a tab of its own. Only a window that held tabs can report
    /// that the user closed them all; one that never saw any is not evidence of anything. A window
    /// left over from a disconnect is exactly that case, and treating its empty tab list as an
    /// instruction deleted the state the disconnect had just saved.
    private(set) var hasObservedTabs = false

    @ObservationIgnored nonisolated(unsafe) private static var shared: [UUID: TabPersistenceCoordinator] = [:]

    /// One per connection, however many windows host it.
    ///
    /// The saved tab set is the connection's, not the window's, so two windows on one connection
    /// must not each keep their own view of whether a restore has run: `hasObservedTabs` is the
    /// gate that stops a partial list being written over a full one, and a second instance starts
    /// with it closed. A detached window's coordinator would then have every save withheld, and
    /// whichever instance the periodic save happened to elect decided whether anything reached
    /// disk at all.
    internal static func forConnection(_ connectionId: UUID) -> TabPersistenceCoordinator {
        if let existing = shared[connectionId] { return existing }
        let created = TabPersistenceCoordinator(connectionId: connectionId)
        shared[connectionId] = created
        return created
    }

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    internal func markObservedTabs() {
        hasObservedTabs = true
    }

    // MARK: - Save

    /// An automatic save never deletes, and never runs before a restore has told it what is on
    /// disk. A workspace that has not bootstrapped yet, a connection still waiting on its driver,
    /// and a window torn down during quit all present a tab list that says nothing about what the
    /// user wants kept. Only `clearForUserClosedAllTabs()` removes state.
    internal func saveNow(tabs: [QueryTab], selectedTabId: UUID?) {
        guard let payload = writablePayload(tabs: tabs, selectedTabId: selectedTabId, path: "saveNow") else {
            return
        }
        scheduleSave(
            tabs: payload.tabs,
            selectedTabId: payload.selectedTabId,
            lastActiveDatabase: payload.database,
            lastActiveSchema: payload.schema
        )
    }

    internal func saveNowSync(tabs: [QueryTab], selectedTabId: UUID?) {
        guard let payload = writablePayload(tabs: tabs, selectedTabId: selectedTabId, path: "saveNowSync") else {
            return
        }
        saveTask?.cancel()
        saveTask = nil
        TabDiskActor.saveSync(
            connectionId: connectionId,
            tabs: payload.tabs,
            selectedTabId: payload.selectedTabId,
            lastActiveDatabase: payload.database,
            lastActiveSchema: payload.schema
        )
    }

    /// The one gate every save passes. Writing a partial list over a full saved set is how tabs
    /// that were never restored get erased, so a save is refused until a restore has run.
    private func writablePayload(
        tabs: [QueryTab],
        selectedTabId: UUID?,
        path: String
    ) -> (tabs: [PersistedTab], selectedTabId: UUID?, database: String?, schema: String?)? {
        guard !tabs.isEmpty else {
            Self.logger.debug(
                "[persist] \(path, privacy: .public) skipped empty tab set connId=\(self.connectionId, privacy: .public)"
            )
            return nil
        }
        guard hasObservedTabs else {
            Self.logger.info(
                "[persist] \(path, privacy: .public) withheld before restore connId=\(self.connectionId, privacy: .public)"
            )
            return nil
        }
        let normalizedSelectedId = tabs.contains(where: { $0.id == selectedTabId })
            ? selectedTabId : tabs.first?.id
        let active = currentActiveDatabaseAndSchema()
        return (tabs.map { $0.toPersistedTab() }, normalizedSelectedId, active.database, active.schema)
    }

    private func currentActiveDatabaseAndSchema() -> (database: String?, schema: String?) {
        guard let session = DatabaseManager.shared.session(for: connectionId) else { return (nil, nil) }
        return (session.browseDatabase, session.browseSchema)
    }

    // MARK: - Clear

    /// Removes the connection's saved tabs. Reserved for the user closing every tab themselves.
    /// No automatic save path may call this: an empty in-memory tab list is not consent to
    /// discard what is on disk.
    internal func clearForUserClosedAllTabs() {
        /// The union across every window hosting the connection, not the manager that just
        /// emptied. Closing a container can empty a detached window while the original still holds
        /// tabs, and discarding the saved set there would take those with it.
        guard MainContentCoordinator.aggregatedTabs(for: connectionId).isEmpty else {
            Self.logger.debug(
                "[persist] clear refused, other windows still hold tabs connId=\(self.connectionId, privacy: .public)"
            )
            return
        }
        saveTask?.cancel()
        saveTask = nil
        let connId = connectionId
        Self.logger.debug("[persist] clearing saved state, user closed all tabs connId=\(connId, privacy: .public)")
        TabDiskActor.clearSync(connectionId: connId)
    }

    // MARK: - Private save scheduling

    private func scheduleSave(
        tabs: [PersistedTab],
        selectedTabId: UUID?,
        lastActiveDatabase: String?,
        lastActiveSchema: String?
    ) {
        saveTask?.cancel()
        let connId = connectionId
        let tabsCopy = tabs
        let selectedId = selectedTabId
        let activeDatabase = lastActiveDatabase
        let activeSchema = lastActiveSchema
        let writeToken = TabDiskActor.issueWriteToken(for: connId)
        Self.logger.debug("[persist] saveNow queued tabCount=\(tabsCopy.count) connId=\(connId, privacy: .public)")

        saveTask = Task {
            guard !Task.isCancelled else { return }
            let t0 = Date()
            do {
                let didWrite = try await TabDiskActor.shared.save(
                    connectionId: connId,
                    tabs: tabsCopy,
                    selectedTabId: selectedId,
                    lastActiveDatabase: activeDatabase,
                    lastActiveSchema: activeSchema,
                    writeToken: writeToken
                )
                guard didWrite else { return }
                Self.logger.debug("[persist] saveNow written tabCount=\(tabsCopy.count) connId=\(connId, privacy: .public) ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
            } catch is CancellationError {
                return
            } catch {
                Self.logger.fault("Failed to save tab state for connection \(connId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Restore

    internal func restoreFromDisk() async -> RestoreResult {
        let state = await TabDiskActor.shared.load(connectionId: connectionId)

        /// The write gate opens once the disk has been read, whether or not it held anything:
        /// knowing the file is empty is as much knowledge as knowing what was in it. Opening it
        /// only on a non-empty read would refuse every save a brand new connection ever makes.
        hasObservedTabs = true

        guard let state, !state.tabs.isEmpty else {
            return RestoreResult(tabs: [], selectedTabId: nil, source: .none)
        }

        let defaultPageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        var restoredTabs = state.tabs.map { QueryTab(from: $0, defaultPageSize: defaultPageSize) }
        FileTabBaseline.hydrate(&restoredTabs)
        RestoredHiddenColumns.hydrate(
            &restoredTabs,
            connectionId: connectionId,
            persister: FileColumnLayoutPersister.shared
        )
        return RestoreResult(
            tabs: restoredTabs,
            selectedTabId: state.selectedTabId,
            source: .disk,
            lastActiveDatabase: state.lastActiveDatabase,
            lastActiveSchema: state.lastActiveSchema,
        )
    }
}
