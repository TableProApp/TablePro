import Foundation

enum SharedConnectionStore {
    private static let appGroupId = "group.com.TablePro.TableProMobile"
    private static let fileName = "widget-connections.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent(fileName)
    }

    static func write(_ items: [WidgetConnectionItem]) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(items) else { return }
        // File protection is intentionally omitted. Widgets must read this file
        // while the device is locked (lock screen widgets, background timeline
        // reloads). Using .completeFileProtection or .completeFileProtectionUnlessOpen
        // would cause reads to fail when the device is locked. The file contains
        // only display metadata (name, type, color) — no credentials or secrets.
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> [WidgetConnectionItem] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([WidgetConnectionItem].self, from: data) else {
            return []
        }
        return items
    }
}
