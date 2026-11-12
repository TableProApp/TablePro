//
//  ConnectionNavigatorExpansionStore.swift
//  TablePro
//

import Foundation

/// Which navigator groups are open, kept apart from the Welcome window's set: the two lists are
/// opened and closed for different reasons, and a narrow column wants fewer groups open.
/// Device-local and never synced, like every other piece of list chrome.
internal struct ConnectionNavigatorExpansionStore {
    internal static let key = "com.TablePro.navigator.groupExpansion"

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    /// A group deleted here or on another Mac leaves its id behind, and nothing could ever reopen
    /// it, so it is dropped on the way in.
    internal func load(keeping groupIds: Set<UUID>) -> Set<UUID> {
        let stored = defaults.stringArray(forKey: Self.key) ?? []
        return Set(stored.compactMap(UUID.init(uuidString:))).intersection(groupIds)
    }

    internal func save(_ ids: Set<UUID>) {
        defaults.set(ids.map(\.uuidString), forKey: Self.key)
    }
}
