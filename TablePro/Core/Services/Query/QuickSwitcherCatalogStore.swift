//
//  QuickSwitcherCatalogStore.swift
//  TablePro
//

import Combine
import Foundation

/// Keeps one connection's quick switcher catalog alive between presentations of the panel.
///
/// The panel builds a fresh view model every time it opens, so closing and reopening it rebuilt the
/// whole catalog: a `fetchDatabases` round trip, a `fetchSchemas` round trip on any driver that
/// switches schemas, and a 200-row history read, for a result that had not changed. Over an SSH
/// tunnel that is the entire time the panel sits empty.
///
/// The cache is keyed on what the catalog is actually a function of, following the same shape as
/// the cross-connection catalog's own version key. Anything the key does not cover has to be
/// signalled: favorites and query history change without the browse scope moving, so this listens
/// for their events and bumps a per-connection revision.
@MainActor
internal final class QuickSwitcherCatalogStore {
    internal struct Version: Hashable {
        internal let browseScope: DatabaseScope?
        internal let schemaGeneration: Int
        internal let isRefreshing: Bool
        internal let databaseFilter: [String]
        internal let contentRevision: Int
        /// The database and schema names the catalog listed, taken from the same metadata service
        /// the sidebar tree reads. Dropping or creating a container refreshes that service and
        /// moves nothing else in this key, so without it a dropped database stayed listed and
        /// committing it failed. Derived from the data rather than a counter someone has to
        /// remember to bump, so a future container mutation invalidates the catalog for free.
        internal let containerNames: [String]
        /// Bumped when the session ends. A load still running at that moment finishes and writes
        /// its catalog under the epoch it started with, so the entry it leaves behind can never be
        /// served to the reconnected session.
        internal let sessionEpoch: Int
    }

    internal static let shared = QuickSwitcherCatalogStore()

    private var items: [UUID: [QuickSwitcherItem]] = [:]
    private var versions: [UUID: Version] = [:]
    private var contentRevisions: [UUID: Int] = [:]
    private var sessionEpochs: [UUID: Int] = [:]
    private var cancellables: Set<AnyCancellable> = []

    #if DEBUG
    /// Test-only init for `@testable` tests in DEBUG builds; release builds must use `.shared`.
    internal init() {
        subscribeToContentChanges()
    }
    #else
    private init() {
        subscribeToContentChanges()
    }
    #endif

    /// A nil connection id on either event means "every connection", which is what the publishers
    /// send when the change was not scoped to one.
    private func subscribeToContentChanges() {
        AppEvents.shared.queryHistoryDidUpdate
            .sink { [weak self] connectionId in self?.bumpContentRevision(for: connectionId) }
            .store(in: &cancellables)
        AppEvents.shared.sqlFavoritesDidUpdate
            .sink { [weak self] connectionId in self?.bumpContentRevision(for: connectionId) }
            .store(in: &cancellables)
    }

    private func bumpContentRevision(for connectionId: UUID?) {
        guard let connectionId else {
            let known = Set(contentRevisions.keys).union(versions.keys)
            for key in known {
                contentRevisions[key, default: 0] &+= 1
            }
            return
        }
        contentRevisions[connectionId, default: 0] &+= 1
    }

    internal func contentRevision(for connectionId: UUID) -> Int {
        contentRevisions[connectionId] ?? 0
    }

    internal func sessionEpoch(for connectionId: UUID) -> Int {
        sessionEpochs[connectionId] ?? 0
    }

    /// Nil whenever the catalog has to be rebuilt, so a caller that gets a value can skip the
    /// fetches entirely rather than racing them.
    internal func catalog(for connectionId: UUID, version: Version) -> [QuickSwitcherItem]? {
        guard versions[connectionId] == version else { return nil }
        return items[connectionId]
    }

    /// Stored without any open-tab state. Which tables have a tab changes between presentations
    /// while none of the version's inputs move, so a cached `isOpenInTab` would badge a table the
    /// user has since closed.
    internal func store(_ catalog: [QuickSwitcherItem], for connectionId: UUID, version: Version) {
        items[connectionId] = catalog.map { item in
            var stored = item
            stored.isOpenInTab = false
            return stored
        }
        versions[connectionId] = version
    }

    /// The epoch deliberately survives removal. Disconnecting resets the schema generation and the
    /// content revision, so a reconnected session recomputes the same version it had before, and a
    /// catalog written by a load that outlived the disconnect would be served as if it were fresh.
    internal func removeConnection(_ connectionId: UUID) {
        items.removeValue(forKey: connectionId)
        versions.removeValue(forKey: connectionId)
        contentRevisions.removeValue(forKey: connectionId)
        sessionEpochs[connectionId, default: 0] &+= 1
    }
}
