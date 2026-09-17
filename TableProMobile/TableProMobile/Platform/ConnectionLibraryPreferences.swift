import Foundation
import Observation
import os
import TableProConnectionLibrary

@MainActor @Observable
final class ConnectionLibraryPreferences {
    static let sortModeKey = "com.TablePro.connectionList.sortMode"
    static let favoritesOrderKey = "com.TablePro.connectionList.favoritesOrder"
    static let recentConnectionsKey = "com.TablePro.connectionList.recentConnections"
    static let collapsedGroupsKey = "com.TablePro.connectionList.collapsedGroups"

    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionLibraryPreferences")

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var sortMode: LibrarySortMode
    private(set) var favoritesOrder: [UUID]
    private(set) var recents: RecentConnectionsLedger
    private(set) var collapsedGroupIds: Set<UUID>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sortMode = defaults.string(forKey: Self.sortModeKey).flatMap(LibrarySortMode.init(rawValue:)) ?? .manual
        favoritesOrder = Self.uuids(defaults.stringArray(forKey: Self.favoritesOrderKey))
        recents = Self.loadRecents(from: defaults)
        collapsedGroupIds = Set(Self.uuids(defaults.stringArray(forKey: Self.collapsedGroupsKey)))
    }

    var lastConnected: [UUID: Date] {
        recents.lastConnected
    }

    func setSortMode(_ mode: LibrarySortMode) {
        guard mode != sortMode else { return }
        sortMode = mode
        defaults.set(mode.rawValue, forKey: Self.sortModeKey)
    }

    func setFavoritesOrder(_ order: [UUID]) {
        var seen: Set<UUID> = []
        let unique = order.filter { seen.insert($0).inserted }
        guard unique != favoritesOrder else { return }
        favoritesOrder = unique
        defaults.set(unique.map(\.uuidString), forKey: Self.favoritesOrderKey)
    }

    func recordConnected(_ connectionId: UUID, at date: Date = Date()) {
        var updated = recents
        updated.record(connectionId, at: date)
        commitRecents(updated)
    }

    func removeFromRecent(_ connectionIds: Set<UUID>) {
        var updated = recents
        updated.remove(connectionIds)
        commitRecents(updated)
    }

    func clearRecent() {
        var updated = recents
        updated.removeAll()
        commitRecents(updated)
    }

    func isGroupExpanded(_ groupId: UUID) -> Bool {
        !collapsedGroupIds.contains(groupId)
    }

    func setGroup(_ groupId: UUID, expanded: Bool) {
        var updated = collapsedGroupIds
        if expanded {
            updated.remove(groupId)
        } else {
            updated.insert(groupId)
        }
        commitCollapsedGroups(updated)
    }

    func prune(connectionIds: Set<UUID>, favoriteIds: Set<UUID>, groupIds: Set<UUID>) {
        setFavoritesOrder(LibraryOrdering.favoritesOrder(favoritesOrder, keeping: favoriteIds))
        var updated = recents
        updated.retain(only: connectionIds)
        commitRecents(updated)
        commitCollapsedGroups(collapsedGroupIds.intersection(groupIds))
    }

    private func commitRecents(_ updated: RecentConnectionsLedger) {
        guard updated != recents else { return }
        recents = updated
        do {
            defaults.set(try JSONEncoder().encode(updated), forKey: Self.recentConnectionsKey)
        } catch {
            Self.logger.error("Failed to save recent connections: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func commitCollapsedGroups(_ updated: Set<UUID>) {
        guard updated != collapsedGroupIds else { return }
        collapsedGroupIds = updated
        defaults.set(updated.map(\.uuidString).sorted(), forKey: Self.collapsedGroupsKey)
    }

    private static func uuids(_ strings: [String]?) -> [UUID] {
        (strings ?? []).compactMap(UUID.init(uuidString:))
    }

    private static func loadRecents(from defaults: UserDefaults) -> RecentConnectionsLedger {
        guard let data = defaults.data(forKey: recentConnectionsKey) else { return RecentConnectionsLedger() }
        do {
            return try JSONDecoder().decode(RecentConnectionsLedger.self, from: data)
        } catch {
            logger.error("Discarding unreadable recent connections: \(error.localizedDescription, privacy: .public)")
            return RecentConnectionsLedger()
        }
    }
}
