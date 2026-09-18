import Foundation
import TableProModels

struct GroupPersistence {
    let directory: URL

    private var fileURL: URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("groups.json")
    }

    func save(_ groups: [ConnectionGroup]) throws {
        guard let fileURL else { return }
        let data = try JSONEncoder().encode(groups)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load() throws -> [ConnectionGroup] {
        guard let fileURL else { return [] }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionGroup].self, from: data)
    }
}
