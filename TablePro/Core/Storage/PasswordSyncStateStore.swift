//
//  PasswordSyncStateStore.swift
//  TablePro
//

import Foundation

struct PasswordSyncStateStore: @unchecked Sendable {
    static let shared = PasswordSyncStateStore(userDefaults: .standard)

    private static let enabledKey = "com.TablePro.keychainPasswordSyncEnabled"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isEnabled: Bool {
        userDefaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ isEnabled: Bool) {
        userDefaults.set(isEnabled, forKey: Self.enabledKey)
    }

    func apply(_ settings: SyncSettings) {
        setEnabled(Self.isEnabled(for: settings))
    }

    static func isEnabled(for settings: SyncSettings) -> Bool {
        settings.enabled && settings.syncConnections && settings.syncPasswords
    }
}
