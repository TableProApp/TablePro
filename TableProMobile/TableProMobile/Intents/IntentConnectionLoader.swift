import Foundation
import TableProModels

enum IntentConnectionLoader {
    static func load() -> [DatabaseConnection] {
        guard let fileURL else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return decode(data)
    }

    static func connection(id: UUID) -> DatabaseConnection? {
        load().first { $0.id == id }
    }

    static func decode(_ data: Data) -> [DatabaseConnection] {
        (try? JSONDecoder().decode([DatabaseConnection].self, from: data)) ?? []
    }

    private static var fileURL: URL? {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return directory
            .appendingPathComponent("TableProMobile", isDirectory: true)
            .appendingPathComponent("connections.json")
    }
}
