//
//  RoutineDebugOptionStore.swift
//  TablePro
//

import Foundation

// The start sheet's option values, per connection and field. Device-local: a debugger host or port names this Mac's network.
internal struct RoutineDebugOptionStore: Sendable {
    private static let keyPrefix = "RoutineDebugOption."

    private let defaults: @Sendable () -> UserDefaults

    init(defaults: @escaping @Sendable () -> UserDefaults = { AppStorageEnvironment.shared.defaults }) {
        self.defaults = defaults
    }

    static func key(connectionId: UUID, fieldId: String) -> String {
        "\(keyPrefix)\(connectionId.uuidString).\(fieldId)"
    }

    func value(for fieldId: String, connectionId: UUID) -> String? {
        defaults().string(forKey: Self.key(connectionId: connectionId, fieldId: fieldId))
    }

    func save(_ values: [String: String], connectionId: UUID) {
        let store = defaults()
        for (fieldId, value) in values {
            store.set(value, forKey: Self.key(connectionId: connectionId, fieldId: fieldId))
        }
    }

    // Field ids are the plugin's, so a connection's keys are found by prefix.
    func remove(for connectionId: UUID) {
        removeKeys(withPrefix: "\(Self.keyPrefix)\(connectionId.uuidString).")
    }

    func removeAll() {
        removeKeys(withPrefix: Self.keyPrefix)
    }

    private func removeKeys(withPrefix prefix: String) {
        let store = defaults()
        for key in store.keys(withPrefix: prefix) {
            store.removeObject(forKey: key)
        }
    }
}
