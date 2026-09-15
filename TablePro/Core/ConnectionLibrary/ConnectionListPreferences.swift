//
//  ConnectionListPreferences.swift
//  TablePro
//

import Combine
import Foundation
import TableProConnectionLibrary

@MainActor
internal final class ConnectionListPreferences {
    internal static let shared = ConnectionListPreferences()

    private let defaults: UserDefaults
    private let appEvents: AppEvents

    internal private(set) var sortMode: LibrarySortMode
    internal private(set) var favoritesOrder: [UUID]

    internal init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        appEvents: AppEvents = .shared
    ) {
        self.defaults = defaults
        self.appEvents = appEvents
        sortMode = defaults.string(forKey: PreferenceKeys.connectionListSortMode.name)
            .flatMap(LibrarySortMode.init(rawValue:)) ?? .manual
        favoritesOrder = (defaults.stringArray(forKey: PreferenceKeys.connectionListFavoritesOrder.name) ?? [])
            .compactMap(UUID.init(uuidString:))
    }

    internal func setSortMode(_ mode: LibrarySortMode) {
        guard mode != sortMode else { return }
        sortMode = mode
        defaults.set(mode.rawValue, forKey: PreferenceKeys.connectionListSortMode.name)
        appEvents.connectionListStateChanged.send(())
    }

    internal func setFavoritesOrder(_ order: [UUID]) {
        var seen: Set<UUID> = []
        let unique = order.filter { seen.insert($0).inserted }
        guard unique != favoritesOrder else { return }
        favoritesOrder = unique
        defaults.set(unique.map(\.uuidString), forKey: PreferenceKeys.connectionListFavoritesOrder.name)
        appEvents.connectionListStateChanged.send(())
    }
}
