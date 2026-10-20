import Foundation

// The records of deleted connections, removed once the saved queries can be written.
nonisolated struct SavedQueryPurge: Codable, Equatable, Sendable {
    let connectionIds: Set<UUID>
    // Only the device that deleted the connection deletes the records in iCloud.
    let tombstoning: Bool
}

nonisolated struct SavedQueryPersistence {
    let directory: URL

    var fileURL: URL {
        directory.appendingPathComponent("saved-queries.json")
    }

    var purgesURL: URL {
        directory.appendingPathComponent("saved-query-purges.json")
    }

    func save(_ contents: SavedQueryContents) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(contents)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load() throws -> SavedQueryContents {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return SavedQueryContents() }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(SavedQueryContents.self, from: data)
    }

    func savePurges(_ purges: [SavedQueryPurge]) throws {
        guard !purges.isEmpty else {
            guard FileManager.default.fileExists(atPath: purgesURL.path) else { return }
            try FileManager.default.removeItem(at: purgesURL)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(purges)
        try data.write(to: purgesURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadPurges() throws -> [SavedQueryPurge] {
        guard FileManager.default.fileExists(atPath: purgesURL.path) else { return [] }
        let data = try Data(contentsOf: purgesURL)
        return try JSONDecoder().decode([SavedQueryPurge].self, from: data)
    }
}
