import Foundation
import TableProModels

struct GroupPersistence {
    private var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appDir = dir.appendingPathComponent("TableProMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("groups.json")
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
