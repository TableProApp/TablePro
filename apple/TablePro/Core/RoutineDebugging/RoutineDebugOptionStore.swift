//
//  RoutineDebugOptionStore.swift
//  TablePro
//

import Foundation

// The start sheet's option values, per connection and field. Device-local: a debugger host or port names this Mac's network.
internal struct RoutineDebugOptionStore: Sendable {
    private let defaults: @Sendable () -> UserDefaults

    init(defaults: @escaping @Sendable () -> UserDefaults = { AppStorageEnvironment.shared.defaults }) {
        self.defaults = defaults
    }

    static func key(connectionId: UUID, fieldId: String) -> String {
        "RoutineDebugOption.\(connectionId.uuidString).\(fieldId)"
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
}
