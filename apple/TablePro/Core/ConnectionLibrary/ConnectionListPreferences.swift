//
//  ConnectionListPreferences.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProConnectionLibrary

@MainActor
internal final class ConnectionListPreferences: ObservableObject {
    internal static let shared = ConnectionListPreferences()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionListPreferences")
    internal static let defaultShowsRecent = true

    private let defaults: UserDefaults
    private let connectionStorageProvider: () -> ConnectionStorage
    private let appEvents: AppEvents

    internal private(set) var sortMode: LibrarySortMode
    @Published internal private(set) var showsRecent: Bool

    internal init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        connectionStorage: @escaping @autoclosure () -> ConnectionStorage = .shared,
        appEvents: AppEvents = .shared
    ) {
        self.defaults = defaults
        self.connectionStorageProvider = connectionStorage
        self.appEvents = appEvents
        sortMode = defaults.string(forKey: PreferenceKeys.connectionListSortMode.name)
            .flatMap(LibrarySortMode.init(rawValue:)) ?? .manual
        showsRecent = defaults.object(forKey: PreferenceKeys.connectionListShowsRecent.name) as? Bool
            ?? Self.defaultShowsRecent
    }

    internal func setSortMode(_ mode: LibrarySortMode) {
        guard mode != sortMode else { return }
        sortMode = mode
        defaults.set(mode.rawValue, forKey: PreferenceKeys.connectionListSortMode.name)
        appEvents.connectionListStateChanged.send(())
    }

    // The library's favourites list, which the core keeps with the connections (core ADR 0010, slice 1b).
    internal var favoritesOrder: [UUID] {
        connectionStorageProvider().library.current()?.favoritesOrder ?? []
    }

    internal func setFavoritesOrder(_ order: [UUID]) {
        var seen: Set<UUID> = []
        let unique = order.filter { seen.insert($0).inserted }
        let library = connectionStorageProvider().library
        guard unique != favoritesOrder, var image = library.current() else { return }
        image.favoritesOrder = unique
        guard library.commit(image, byUser: false) else {
            Self.logger.error("The favourites order was not saved")
            return
        }
        appEvents.connectionListStateChanged.send(())
    }

    internal func setShowsRecent(_ showsRecent: Bool) {
        guard showsRecent != self.showsRecent else { return }
        defaults.set(showsRecent, forKey: PreferenceKeys.connectionListShowsRecent.name)
        self.showsRecent = showsRecent
    }

    internal func resetShowsRecent() {
        defaults.removeObject(forKey: PreferenceKeys.connectionListShowsRecent.name)
        guard showsRecent != Self.defaultShowsRecent else { return }
        showsRecent = Self.defaultShowsRecent
    }
}
