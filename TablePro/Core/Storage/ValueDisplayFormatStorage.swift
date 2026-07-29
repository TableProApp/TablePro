//
//  ValueDisplayFormatStorage.swift
//  TablePro
//

import Foundation

@MainActor
internal final class ValueDisplayFormatStorage {
    static let shared = ValueDisplayFormatStorage()

    private let store: KeyValueStore

    init(defaults: KeyValueStore = UserDefaults.standard) {
        store = defaults
    }

    func save(_ formats: [String: ValueDisplayFormat], for scope: TableScope) {
        guard !formats.isEmpty else {
            clear(for: scope)
            return
        }
        guard let data = try? JSONEncoder().encode(formats) else { return }
        store.setDataValue(data, forKey: PreferenceKeys.columnDisplayFormats(scope).name)
        removeLegacy(for: scope)
    }

    func load(for scope: TableScope) -> [String: ValueDisplayFormat]? {
        if let data = store.dataValue(forKey: PreferenceKeys.columnDisplayFormats(scope).name),
           let formats = try? JSONDecoder().decode([String: ValueDisplayFormat].self, from: data) {
            return formats
        }
        return migrateLegacy(for: scope)
    }

    func clear(for scope: TableScope) {
        store.setDataValue(nil, forKey: PreferenceKeys.columnDisplayFormats(scope).name)
        removeLegacy(for: scope)
    }

    private func migrateLegacy(for scope: TableScope) -> [String: ValueDisplayFormat]? {
        let legacyKey = Self.legacyKey(for: scope)
        guard let data = store.dataValue(forKey: legacyKey),
              let formats = try? JSONDecoder().decode([String: ValueDisplayFormat].self, from: data),
              !formats.isEmpty else {
            return nil
        }
        if let encoded = try? JSONEncoder().encode(formats) {
            store.setDataValue(encoded, forKey: PreferenceKeys.columnDisplayFormats(scope).name)
        }
        store.setDataValue(nil, forKey: legacyKey)
        return formats
    }

    private func removeLegacy(for scope: TableScope) {
        store.setDataValue(nil, forKey: Self.legacyKey(for: scope))
    }

    private static func legacyKey(for scope: TableScope) -> String {
        "com.TablePro.columns.displayFormat.\(scope.connectionId.uuidString).\(scope.table)"
    }
}
