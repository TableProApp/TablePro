//
//  KeychainProviderState.swift
//  TablePro
//

import Foundation

// Which provider this Mac's secrets follow (core ADR 0054, Providers). On iCloud, or with sync off, the password sync
// switch decides as before. On TablePro Sync each secret is this Mac's own item beside its envelope, and an iCloud
// Keychain item stays as it is: removing one removes it on every device still on iCloud.
nonisolated struct KeychainProviderState: Equatable, Sendable {
    var onTableProSync: Bool
    // Every iCloud Keychain item has an item of this Mac's own, so a missing one is a secret removed here, which the
    // iCloud copy must not bring back.
    var deviceCopiesAdded: Bool

    static let followsPasswordSync = KeychainProviderState(onTableProSync: false, deviceCopiesAdded: false)
}

nonisolated protocol KeychainProviderRecord: Sendable {
    var state: KeychainProviderState { get }
    func store(_ state: KeychainProviderState)
    // A secret removed here on TablePro Sync before every copy was made: neither a read nor a later copy brings its
    // iCloud value back.
    func isRemovedHere(_ key: String) -> Bool
    func noteRemovedHere(_ key: String)
    func noteSavedHere(_ key: String)
}

nonisolated final class DefaultsKeychainProviderRecord: KeychainProviderRecord, @unchecked Sendable {
    static let providerKey = "com.TablePro.keychainProvider"
    static let deviceCopiesAddedKey = "com.TablePro.keychainDeviceCopiesAdded"
    static let removedHereKey = "com.TablePro.keychainRemovedBeforeDeviceCopies"
    private static let tableProSync = "tableproSync"

    private let defaults: @Sendable () -> UserDefaults
    private let lock = NSLock()

    init(defaults: @escaping @Sendable () -> UserDefaults = { AppStorageEnvironment.shared.defaults }) {
        self.defaults = defaults
    }

    var state: KeychainProviderState {
        let defaults = defaults()
        guard defaults.string(forKey: Self.providerKey) == Self.tableProSync else { return .followsPasswordSync }
        return KeychainProviderState(onTableProSync: true, deviceCopiesAdded: defaults.bool(forKey: Self.deviceCopiesAddedKey))
    }

    // Once every copy exists, or off TablePro Sync, no read falls back to an iCloud item, so the removals are done.
    func store(_ state: KeychainProviderState) {
        let defaults = defaults()
        lock.withLock {
            if state.onTableProSync {
                defaults.set(Self.tableProSync, forKey: Self.providerKey)
                defaults.set(state.deviceCopiesAdded, forKey: Self.deviceCopiesAddedKey)
            } else {
                defaults.removeObject(forKey: Self.providerKey)
                defaults.removeObject(forKey: Self.deviceCopiesAddedKey)
            }
            if !state.onTableProSync || state.deviceCopiesAdded {
                defaults.removeObject(forKey: Self.removedHereKey)
            }
        }
    }

    func isRemovedHere(_ key: String) -> Bool {
        lock.withLock { removed().contains(key) }
    }

    func noteRemovedHere(_ key: String) {
        lock.withLock {
            var keys = removed()
            guard keys.insert(key).inserted else { return }
            defaults().set(keys.sorted(), forKey: Self.removedHereKey)
        }
    }

    func noteSavedHere(_ key: String) {
        lock.withLock {
            var keys = removed()
            guard keys.remove(key) != nil else { return }
            defaults().set(keys.sorted(), forKey: Self.removedHereKey)
        }
    }

    private func removed() -> Set<String> {
        Set(defaults().stringArray(forKey: Self.removedHereKey) ?? [])
    }
}
