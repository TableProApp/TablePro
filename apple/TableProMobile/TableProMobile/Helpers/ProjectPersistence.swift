import Foundation
import TableProModels

struct ProjectPersistence {
    private let file: LibraryFile<ConnectionProject>

    var unreadableIds: Set<UUID> { file.unreadableIds }

    init(directory: URL) {
        file = LibraryFile(directory: directory, name: "projects.json")
    }

    func save(_ projects: [ConnectionProject], removingUnreadable removedIds: Set<UUID> = []) throws {
        try file.save(projects, removingUnreadable: removedIds)
    }

    func load() throws -> [ConnectionProject] {
        try file.load()?.elements ?? []
    }
}
