import Foundation
import TableProConnectionLibrary
import TableProModels

nonisolated enum IntentConnectionLoader {
    // Every connection, whatever its project: a saved shortcut, a link or a widget tap names one by id.
    static func load() -> [DatabaseConnection] {
        guard let directory else { return [] }
        return load(in: directory)
    }

    static func connection(id: UUID) -> DatabaseConnection? {
        load().first { $0.id == id }
    }

    // What a picker offers: the active project's connections, like the list in the app.
    static func suggested() -> [DatabaseConnection] {
        guard let directory else { return [] }
        return suggested(in: directory, defaults: .standard)
    }

    static func load(in directory: URL) -> [DatabaseConnection] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("connections.json")) else { return [] }
        return decode(data)
    }

    static func suggested(in directory: URL, defaults: UserDefaults) -> [DatabaseConnection] {
        let connections = load(in: directory)
        guard let activeProjectId = ConnectionLibraryPreferences.activeProjectId(in: defaults),
              let groups: [ConnectionGroup] = list("groups.json", in: directory),
              let projects: [ConnectionProject] = list("projects.json", in: directory)
        else { return connections }
        return LibraryProjectScope.scoped(
            connections: connections,
            groups: groups,
            projects: projects,
            active: activeProjectId
        ).connections
    }

    static func decode(_ data: Data) -> [DatabaseConnection] {
        (try? LibraryFileRecords<DatabaseConnection>(decoding: data).elements) ?? []
    }

    // Empty when there is no file, nil when the file cannot be read: membership is unknown then, so nothing is hidden.
    private static func list<Element: Codable>(_ name: String, in directory: URL) -> [Element]? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? LibraryFileRecords<Element>(decoding: data).elements
    }

    private static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TableProMobile", isDirectory: true)
    }
}
