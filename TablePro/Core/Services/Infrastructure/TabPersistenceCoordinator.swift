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
    /// Which window each tab belongs to, by tab id. Kept beside the tabs rather than on `QueryTab`,
    /// because it describes where a tab was rather than anything about the tab, and it is read once
    /// while a window works out which tabs are its own.
    var windowGroupIndexByTabId: [UUID: Int] = [:]
    /// The container each saved window group was browsing, keyed by the same group numbering the
    /// tabs carry. Read through `browseState(forWindowGroupIndex:)`, never directly, so the legacy
    /// fallback cannot be skipped by a new call site.
    var browseStateByWindowGroup: [Int: WindowBrowseState] = [:]

    enum RestoreSource {
        case disk
        case none
    }

    /// The cursor one restoring window group starts on.
    ///
    /// A group with no entry of its own falls back to the single connection-wide container, which
    /// is all that state written by an older build carries. That fallback is what makes the new
    /// field additive: without it, every window of an upgrading user would come back on the
    /// connection default instead of the container it was left showing. (#2088)
    func browseState(forWindowGroupIndex index: Int) -> WindowBrowseState {
        browseStateByWindowGroup[index]
            ?? WindowBrowseState.seeded(database: lastActiveDatabase, schema: lastActiveSchema)
    }

    static func browseStates(from state: TabDiskState) -> [Int: WindowBrowseState] {
        guard let persisted = state.windowBrowseStates else { return [:] }
        return Dictionary(
            persisted.map {
                ($0.windowGroupIndex, WindowBrowseState.seeded(database: $0.database, schema: $0.schema))
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }
}

@MainActor @Observable
internal final class TabPersistenceCoordinator {
    internal static let logger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")
    let connectionId: UUID

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Whether this window has ever had a tab of its own. Only a window that held tabs can report
    /// that the user closed them all; one that never saw any is not evidence of anything. A window
    /// left over from a disconnect is exactly that case, and treating its empty tab list as an
    /// instruction deleted the state the disconnect had just saved.
    private(set) var hasObservedTabs = false

    /// The last browse cursor seen for each of the connection's window groups.
    ///
    /// A save reads cursors off the coordinators still registered for the connection, and nothing
    /// sequences teardown against a save: on quit and on disconnect a window can already be gone
    /// when the aggregated save runs. Persisting only what is live would store that group's tabs
    /// with no container of their own, so the group would come back on the connection default
    /// rather than where the user left it. The last value seen beats nil every time. (#2088)
    private var lastKnownBrowseStates: [Int: WindowBrowseState] = [:]

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    internal func markObservedTabs() {
        hasObservedTabs = true
    }

    // MARK: - Save

    internal func saveNow(
        tabs: [QueryTab],
        selectedTabId: UUID?,
        browseState: WindowBrowseState? = nil
    ) {
        saveNow(
            windowedTabs: tabs.map { (tab: $0, windowGroupIndex: 0) },
            selectedTabId: selectedTabId,
            browseStates: browseState.map { [0: $0] } ?? [:]
        )
    }

    /// An automatic save never deletes. A window that has not restored yet, a connection still
    /// waiting on its driver, and a window torn down during quit all present an empty tab list
    /// that says nothing about what the user wants kept, so treating it as a delete instruction
    /// destroys drafts the user never closed. Only `clearForUserClosedAllTabs()` removes state.
    internal func saveNow(
        windowedTabs: [(tab: QueryTab, windowGroupIndex: Int)],
        selectedTabId: UUID?,
        browseStates: [Int: WindowBrowseState]
    ) {
        guard !windowedTabs.isEmpty else {
            Self.logger.debug("[persist] saveNow skipped empty tab set connId=\(self.connectionId, privacy: .public)")
            return
        }
        hasObservedTabs = true
        let persisted = windowedTabs.map { $0.tab.toPersistedTab(windowGroupIndex: $0.windowGroupIndex) }
        let normalizedSelectedId = windowedTabs.contains(where: { $0.tab.id == selectedTabId })
            ? selectedTabId : windowedTabs.first?.tab.id
        rememberBrowseStates(browseStates)
        let browse = persistedBrowse(forWindowGroups: Set(windowedTabs.map(\.windowGroupIndex)))
        scheduleSave(
            tabs: persisted,
            selectedTabId: normalizedSelectedId,
            windowBrowseStates: browse
        )
    }

    internal func saveNowSync(
        tabs: [QueryTab],
        selectedTabId: UUID?,
        browseState: WindowBrowseState? = nil
    ) {
        saveNowSync(
            windowedTabs: tabs.map { (tab: $0, windowGroupIndex: 0) },
            selectedTabId: selectedTabId,
            browseStates: browseState.map { [0: $0] } ?? [:]
        )
    }

    internal func saveNowSync(
        windowedTabs: [(tab: QueryTab, windowGroupIndex: Int)],
        selectedTabId: UUID?,
        browseStates: [Int: WindowBrowseState]
    ) {
        guard !windowedTabs.isEmpty else {
            Self.logger.debug("[persist] saveNowSync skipped empty tab set connId=\(self.connectionId, privacy: .public)")
            return
        }
        hasObservedTabs = true
        let persisted = windowedTabs.map { $0.tab.toPersistedTab(windowGroupIndex: $0.windowGroupIndex) }
        let normalizedSelectedId = windowedTabs.contains(where: { $0.tab.id == selectedTabId })
            ? selectedTabId : windowedTabs.first?.tab.id
        rememberBrowseStates(browseStates)
        let browse = persistedBrowse(forWindowGroups: Set(windowedTabs.map(\.windowGroupIndex)))
        TabDiskActor.saveSync(
            connectionId: connectionId,
            tabs: persisted,
            selectedTabId: normalizedSelectedId,
            lastActiveDatabase: browse.first?.database,
            lastActiveSchema: browse.first?.schema,
            windowBrowseStates: browse.isEmpty ? nil : browse
        )
    }

    private func rememberBrowseStates(_ observed: [Int: WindowBrowseState]) {
        lastKnownBrowseStates.merge(observed) { _, latest in latest }
    }

    /// One entry per window group being saved, in group order, dropping any cursor that names no
    /// container: an entry present but empty would be applied over a window the payload had already
    /// seeded, while an absent one lets that window fall back.
    private func persistedBrowse(forWindowGroups windowGroupIndices: Set<Int>) -> [PersistedWindowBrowse] {
        lastKnownBrowseStates
            .filter { windowGroupIndices.contains($0.key) && !$0.value.isUnset }
            .sorted { $0.key < $1.key }
            .map {
                PersistedWindowBrowse(
                    windowGroupIndex: $0.key,
                    database: $0.value.database,
                    schema: $0.value.schema
                )
            }
    }

    // MARK: - Clear

    /// Removes the connection's saved tabs. Reserved for the user closing every tab themselves.
    /// No automatic save path may call this: an empty in-memory tab list is not consent to
    /// discard what is on disk.
    internal func clearForUserClosedAllTabs() {
        saveTask?.cancel()
        saveTask = nil
        let connId = connectionId
        Self.logger.debug("[persist] clearing saved state, user closed all tabs connId=\(connId, privacy: .public)")
        TabDiskActor.clearSync(connectionId: connId)
    }

    // MARK: - Private save scheduling

    /// The legacy single container is still written, from the leftmost group, so a user who rolls
    /// back to a build that only reads that field lands on a container one of their windows was
    /// really on rather than on the connection default.
    private func scheduleSave(
        tabs: [PersistedTab],
        selectedTabId: UUID?,
        windowBrowseStates: [PersistedWindowBrowse]
    ) {
        saveTask?.cancel()
        let connId = connectionId
        let tabsCopy = tabs
        let selectedId = selectedTabId
        let browse = windowBrowseStates
        Self.logger.debug("[persist] saveNow queued tabCount=\(tabsCopy.count) connId=\(connId, privacy: .public)")

        saveTask = Task {
            guard !Task.isCancelled else { return }
            let t0 = Date()
            do {
                try await TabDiskActor.shared.save(
                    connectionId: connId,
                    tabs: tabsCopy,
                    selectedTabId: selectedId,
                    lastActiveDatabase: browse.first?.database,
                    lastActiveSchema: browse.first?.schema,
                    windowBrowseStates: browse.isEmpty ? nil : browse
                )
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
        guard let state = await TabDiskActor.shared.load(connectionId: connectionId) else {
            return RestoreResult(tabs: [], selectedTabId: nil, source: .none)
        }

        guard !state.tabs.isEmpty else {
            return RestoreResult(tabs: [], selectedTabId: nil, source: .none)
        }
        hasObservedTabs = true

        let defaultPageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        var restoredTabs = state.tabs.map { QueryTab(from: $0, defaultPageSize: defaultPageSize) }
        for index in restoredTabs.indices {
            guard let url = restoredTabs[index].content.sourceFileURL else { continue }
            if let loaded = FileTextLoader.load(url) {
                restoredTabs[index].content.savedFileContent = loaded.content
                restoredTabs[index].content.loadMtime = (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            }
        }
        return RestoreResult(
            tabs: restoredTabs,
            selectedTabId: state.selectedTabId,
            source: .disk,
            lastActiveDatabase: state.lastActiveDatabase,
            lastActiveSchema: state.lastActiveSchema,
            windowGroupIndexByTabId: WindowGroupAssignment.normalizedGroupIndices(for: state.tabs),
            browseStateByWindowGroup: RestoreResult.browseStates(from: state)
        )
    }
}
