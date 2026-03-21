//
//  ColumnLayoutStorage.swift
//  TablePro
//

import Foundation

@MainActor
internal final class ColumnLayoutStorage {
    static let shared = ColumnLayoutStorage()

    private init() {}

    // MARK: - Types

    private struct PersistedColumnLayout: Codable {
        var columnWidths: [String: CGFloat]
        var columnOrder: [String]?
    }

    // MARK: - Public API

    func save(_ layout: ColumnLayoutState, for tableName: String, connectionId: UUID) {
        guard !layout.columnWidths.isEmpty else { return }

        let persisted = PersistedColumnLayout(
            columnWidths: layout.columnWidths,
            columnOrder: layout.columnOrder
        )
        let key = Self.userDefaultsKey(tableName: tableName, connectionId: connectionId)
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func load(for tableName: String, connectionId: UUID) -> ColumnLayoutState? {
        let key = Self.userDefaultsKey(tableName: tableName, connectionId: connectionId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let persisted = try? JSONDecoder().decode(PersistedColumnLayout.self, from: data)
        else {
            return nil
        }
        var state = ColumnLayoutState()
        state.columnWidths = persisted.columnWidths
        state.columnOrder = persisted.columnOrder
        return state
    }

    func clear(for tableName: String, connectionId: UUID) {
        let key = Self.userDefaultsKey(tableName: tableName, connectionId: connectionId)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Private

    private static func userDefaultsKey(tableName: String, connectionId: UUID) -> String {
        "com.TablePro.columns.layout.\(connectionId.uuidString).\(tableName)"
    }
}
