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
        guard let elements = try? JSONDecoder().decode([FailableConnection].self, from: data) else {
            return []
        }
        return elements.compactMap(\.value)
    }

    private struct FailableConnection: Decodable {
        let value: DatabaseConnection?

        init(from decoder: Decoder) throws {
            value = try? DatabaseConnection(from: decoder)
        }
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
