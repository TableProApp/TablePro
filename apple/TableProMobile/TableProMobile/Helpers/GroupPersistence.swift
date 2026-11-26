import Foundation
import TableProModels

struct GroupPersistence {
    private let file: LibraryFile<ConnectionGroup>

    var unreadableIds: Set<UUID> { file.unreadableIds }

    init(directory: URL) {
        file = LibraryFile(directory: directory, name: "groups.json")
    }

    func save(
        _ groups: [ConnectionGroup],
        removingUnreadable removedIds: Set<UUID> = [],
        willWrite: (Data) -> Void = { _ in }
    ) throws {
        try file.save(groups, removingUnreadable: removedIds, willWrite: willWrite)
    }

    func load() throws -> [ConnectionGroup] {
        try file.load()?.elements ?? []
    }
}
