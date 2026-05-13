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

    func save(_ groups: [ConnectionGroup]) {
        guard let fileURL, let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    func load() -> [ConnectionGroup] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let groups = try? JSONDecoder().decode([ConnectionGroup].self, from: data) else {
            return []
        }
        return groups
    }
}
