import Foundation
import os
import TableProModels

struct GroupPersistence {
    private static let logger = Logger(subsystem: "com.TablePro", category: "GroupPersistence")

    private var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appDir = dir.appendingPathComponent("TableProMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("groups.json")
    }

    func save(_ groups: [ConnectionGroup]) {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(groups)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("Failed to save groups: \(error.localizedDescription, privacy: .public)")
        }
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
