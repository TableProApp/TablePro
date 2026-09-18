import Foundation
import TableProModels

struct TagPersistence {
    let directory: URL

    private var fileURL: URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("tags.json")
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
