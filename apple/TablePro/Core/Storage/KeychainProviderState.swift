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

    static let providerKey = "com.TablePro.keychainProvider"
    static let deviceCopiesAddedKey = "com.TablePro.keychainDeviceCopiesAdded"
    private static let tableProSync = "tableproSync"

    static func stored(in defaults: UserDefaults) -> KeychainProviderState {
        guard defaults.string(forKey: providerKey) == tableProSync else { return .followsPasswordSync }
        return KeychainProviderState(onTableProSync: true, deviceCopiesAdded: defaults.bool(forKey: deviceCopiesAddedKey))
    }

    func store(in defaults: UserDefaults) {
        if onTableProSync {
            defaults.set(Self.tableProSync, forKey: Self.providerKey)
            defaults.set(deviceCopiesAdded, forKey: Self.deviceCopiesAddedKey)
        } else {
            defaults.removeObject(forKey: Self.providerKey)
            defaults.removeObject(forKey: Self.deviceCopiesAddedKey)
        }
    }
}
