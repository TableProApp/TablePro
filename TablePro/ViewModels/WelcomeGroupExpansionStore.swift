//
//  WelcomeGroupExpansionStore.swift
//  TablePro
//

import Foundation

internal struct WelcomeGroupExpansionStore {
    private static let key = "com.TablePro.expandedGroupIds"

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    internal func load() -> Set<UUID>? {
        guard let stored = defaults.stringArray(forKey: Self.key) else { return nil }
        return Set(stored.compactMap(UUID.init(uuidString:)))
    }

    internal func save(_ ids: Set<UUID>) {
        defaults.set(ids.map(\.uuidString), forKey: Self.key)
    }
}
