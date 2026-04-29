//
//  ValueDisplayFormatStorage.swift
//  TablePro
//

import Foundation

@MainActor
internal final class ValueDisplayFormatStorage {
    static let shared = ValueDisplayFormatStorage()

    private init() {}

    // MARK: - Public API

    func save(_ formats: [String: ValueDisplayFormat], for tableName: String, connectionId: UUID) {
        guard !formats.isEmpty else {
            clear(for: tableName, connectionId: connectionId)
            return
        }

        let key = Self.userDefaultsKey(tableName: tableName, connectionId: connectionId)
        if let data = try? JSONEncoder().encode(formats) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func load(for tableName: String, connectionId: UUID) -> [String: ValueDisplayFormat]? {
        let key = Self.userDefaultsKey(tableName: tableName, connectionId: connectionId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let formats = try? JSONDecoder().decode([String: ValueDisplayFormat].self, from: data)
        else {
            return nil
        }
        return formats
    }

    func clear(for tableName: String, connectionId: UUID) {
        let key = Self.userDefaultsKey(tableName: tableName, connectionId: connectionId)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Private

    private static func userDefaultsKey(tableName: String, connectionId: UUID) -> String {
        "com.TablePro.columns.displayFormat.\(connectionId.uuidString).\(tableName)"
    }
}
