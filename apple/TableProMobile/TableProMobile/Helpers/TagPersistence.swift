import Foundation
import TableProModels

struct TagPersistence {
    private let file: LibraryFile<ConnectionTag>

    init(directory: URL) {
        file = LibraryFile(directory: directory, name: "tags.json")
    }

    var unreadableIds: Set<UUID> { file.unreadableIds }

    func save(_ tags: [ConnectionTag], removingUnreadable removedIds: Set<UUID> = []) throws {
        try file.save(tags, removingUnreadable: removedIds)
    }

    func load() throws -> [ConnectionTag] {
        guard let tags = try file.load()?.elements else { return ConnectionTag.presets }
        // Only a file with nothing in it takes the presets: a kept record with a preset's id would give way to them.
        return tags.isEmpty && !file.holdsUnreadableRecords ? ConnectionTag.presets : tags
    }
}
