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

    func save(_ tags: [ConnectionTag]) {
        guard let fileURL, let data = try? JSONEncoder().encode(tags) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    func load() -> [ConnectionTag] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let tags = try? JSONDecoder().decode([ConnectionTag].self, from: data),
              !tags.isEmpty else {
            return ConnectionTag.presets
        }
        return tags
    }
}
