import Foundation
import TableProModels

struct StoredConnections {
    let connections: [DatabaseConnection]
    let pastedSSHKeys: [UUID: String]
}

struct ConnectionPersistence {
    private let file: LibraryFile<DatabaseConnection>

    var unreadableIds: Set<UUID> { file.unreadableIds }

    init(directory: URL) {
        file = LibraryFile(directory: directory, name: "connections.json")
    }

    func save(
        _ connections: [DatabaseConnection],
        keepingPastedSSHKeys pastedSSHKeys: [UUID: String],
        removingSecrets: Bool = false,
        removingUnreadable removedIds: Set<UUID> = [],
        willWrite: (Data) -> Void = { _ in }
    ) throws {
        let encoder = JSONEncoder()
        encoder.userInfo[.deviceLibraryFile] = true
        try file.save(
            connections,
            using: encoder,
            removingSecrets: removingSecrets,
            removingUnreadable: removedIds,
            willWrite: willWrite
        ) {
            try PastedSSHKeyMigration.libraryFile($0, keeping: pastedSSHKeys)
        }
    }

    func load() throws -> StoredConnections {
        guard let loaded = try file.load() else {
            return StoredConnections(connections: [], pastedSSHKeys: [:])
        }
        return StoredConnections(
            connections: loaded.elements,
            pastedSSHKeys: PastedSSHKeyMigration.pendingKeys(inLibraryFile: loaded.data)
        )
    }
}
