import Foundation
import TableProModels

struct TagPersistence {
    private var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appDir = dir.appendingPathComponent("TableProMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("tags.json")
    }

    func save(_ tags: [ConnectionTag]) throws {
        guard let fileURL else { return }
        let data = try JSONEncoder().encode(tags)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load() throws -> [ConnectionTag] {
        guard let fileURL else { return ConnectionTag.presets }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            return ConnectionTag.presets
        }
        let data = try Data(contentsOf: fileURL)
        let tags = try JSONDecoder().decode([ConnectionTag].self, from: data)
        return tags.isEmpty ? ConnectionTag.presets : tags
    }
}
