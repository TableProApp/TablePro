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
