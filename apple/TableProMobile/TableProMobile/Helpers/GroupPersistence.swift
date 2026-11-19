import Foundation
import TableProModels

struct GroupPersistence {
    private let file: LibraryFile<ConnectionGroup>

    var unreadableIds: Set<UUID> { file.unreadableIds }

    init(directory: URL) {
        file = LibraryFile(directory: directory, name: "groups.json")
    }

    func save(_ groups: [ConnectionGroup], removingUnreadable removedIds: Set<UUID> = []) throws {
        try file.save(groups, removingUnreadable: removedIds)
    }

    func load() throws -> [ConnectionGroup] {
        try file.load()?.elements ?? []
    }
}
