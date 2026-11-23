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
///
/// The catalog is kept in two parts. The containers, routines, triggers and types come from the
/// server; the favorites and history are local reads. Opening a table records history, so one
/// version for both made the next open refetch the database and schema lists for a change that
/// cannot touch them. Each part misses only on what it is built from.
@MainActor
internal final class QuickSwitcherCatalogStore {
    internal struct Version: Hashable {
        internal let browseScope: DatabaseScope?
        internal let schemaGeneration: Int
        internal let isRefreshing: Bool
        internal let databaseFilter: [String]
        internal let schemaFilter: [String]
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

        fileprivate var containerKey: ContainerKey {
            ContainerKey(
                browseScope: browseScope,
                schemaGeneration: schemaGeneration,
                isRefreshing: isRefreshing,
                databaseFilter: databaseFilter,
                schemaFilter: schemaFilter,
                containerNames: containerNames,
                sessionEpoch: sessionEpoch
            )
        }

        fileprivate var contentKey: ContentKey {
            ContentKey(contentRevision: contentRevision, sessionEpoch: sessionEpoch)
        }
    }

    fileprivate struct ContainerKey: Hashable {
        let browseScope: DatabaseScope?
        let schemaGeneration: Int
        let isRefreshing: Bool
        let databaseFilter: [String]
        let schemaFilter: [String]
        let containerNames: [String]
        let sessionEpoch: Int
    }

    fileprivate struct ContentKey: Hashable {
        let contentRevision: Int
        let sessionEpoch: Int
    }

    private struct Part<Key: Hashable> {
        var items: [UUID: [QuickSwitcherItem]] = [:]
        var keys: [UUID: Key] = [:]

        func items(for connectionId: UUID, key: Key) -> [QuickSwitcherItem]? {
            guard keys[connectionId] == key else { return nil }
            return items[connectionId]
        }

        mutating func store(_ catalog: [QuickSwitcherItem], for connectionId: UUID, key: Key) {
            items[connectionId] = catalog
            keys[connectionId] = key
        }

        mutating func remove(_ connectionId: UUID) {
            items.removeValue(forKey: connectionId)
            keys.removeValue(forKey: connectionId)
        }
    }

    internal static let shared = QuickSwitcherCatalogStore()

    private var containers = Part<ContainerKey>()
    private var content = Part<ContentKey>()
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
            let known = Set(contentRevisions.keys).union(containers.keys.keys).union(content.keys.keys)
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

    /// The databases, schemas, routines, triggers and types, or nil when they have to be fetched
    /// again, so a caller that gets a value can skip the fetches entirely rather than racing them.
    internal func containers(for connectionId: UUID, version: Version) -> [QuickSwitcherItem]? {
        containers.items(for: connectionId, key: version.containerKey)
    }

    /// The saved queries and history, or nil when they have to be read again.
    internal func content(for connectionId: UUID, version: Version) -> [QuickSwitcherItem]? {
        content.items(for: connectionId, key: version.contentKey)
    }

    /// The panel keeps no tables here. They change without any of the version's inputs moving, a
    /// schema listed after the panel opened or a tab opened since, so it merges them in live. Open
    /// state is stripped all the same, so nothing stored can badge a tab the user has closed.
    internal func storeContainers(_ catalog: [QuickSwitcherItem], for connectionId: UUID, version: Version) {
        containers.store(Self.closed(catalog), for: connectionId, key: version.containerKey)
    }

    internal func storeContent(_ catalog: [QuickSwitcherItem], for connectionId: UUID, version: Version) {
        content.store(Self.closed(catalog), for: connectionId, key: version.contentKey)
    }

    private static func closed(_ catalog: [QuickSwitcherItem]) -> [QuickSwitcherItem] {
        catalog.map { item in
            var stored = item
            stored.isOpenInTab = false
            return stored
        }
    }

    /// The epoch deliberately survives removal. Disconnecting resets the schema generation and the
    /// content revision, so a reconnected session recomputes the same version it had before, and a
    /// catalog written by a load that outlived the disconnect would be served as if it were fresh.
    internal func removeConnection(_ connectionId: UUID) {
        containers.remove(connectionId)
        content.remove(connectionId)
        contentRevisions.removeValue(forKey: connectionId)
        sessionEpochs[connectionId, default: 0] &+= 1
    }
}
