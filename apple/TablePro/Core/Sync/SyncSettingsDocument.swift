import Foundation

// A settings record can hold options a newer build wrote. This build's types drop them on decode, so a push puts
// them back from the record it builds on, or a Mac on an older build resets them on every other Mac.
enum SyncSettingsDocument {
    // Nil when `source` cannot be read as this category, so nothing can be told apart in it.
    static func carryingUnreadOptions(of source: Data?, into local: Data, category: String) -> Data? {
        guard let source,
              let sourceObject = object(source),
              let readObject = readBack(source, category: category).flatMap(object),
              var localObject = object(local)
        else { return nil }
        let unread = sourceObject.filter { readObject[$0.key] == nil && localObject[$0.key] == nil }
        guard !unread.isEmpty else { return local }
        localObject.merge(unread) { mine, _ in mine }
        return try? JSONSerialization.data(withJSONObject: localObject, options: [.sortedKeys])
    }

    // What this build keeps of a document: decoded with its own type and written again.
    private static func readBack(_ data: Data, category: String) -> Data? {
        switch category {
        case AppSettingsCategory.general: roundTrip(GeneralSettings.self, data)
        case AppSettingsCategory.appearance: roundTrip(AppearanceSettings.self, data)
        case AppSettingsCategory.editor: roundTrip(EditorSettings.self, data)
        case AppSettingsCategory.dataGrid: roundTrip(DataGridSettings.self, data)
        case AppSettingsCategory.history: roundTrip(HistorySettings.self, data)
        case AppSettingsCategory.tabs: roundTrip(TabSettings.self, data)
        case AppSettingsCategory.keyboard: roundTrip(KeyboardSettings.self, data)
        case AppSettingsCategory.ai: roundTrip(AISettings.self, data)
        case AppSettingsCategory.notifications: roundTrip(NotificationSettings.self, data)
        case AppSettingsCategory.formatter: roundTrip(SQLFormatterSettings.self, data)
        case AppSettingsCategory.valueColors: roundTrip(ValueColorSettings.self, data)
        default: nil
        }
    }

    private static func roundTrip<Settings: Codable>(_: Settings.Type, _ data: Data) -> Data? {
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return nil }
        return try? JSONEncoder().encode(settings)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
