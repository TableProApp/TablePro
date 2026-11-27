import Foundation
import TableProConnectionLibrary

public struct ImportedProject: Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let color: String?
    public let iconName: String?
    public let sortOrder: Int

    public init(id: UUID, name: String, color: String?, iconName: String?, sortOrder: Int) {
        self.id = id
        self.name = name
        self.color = color
        self.iconName = iconName
        self.sortOrder = sortOrder
    }
}

public enum ImportProjectResolver {
    private struct Entry: LibraryProjectRepresentable {
        let id: UUID
        let name: String
        let sortOrder: Int
    }

    // `takenIds` are ids a new project cannot use, such as a record this build cannot read.
    public static func resolve<Project: LibraryProjectRepresentable>(
        _ planned: [PlannedProject],
        existing: [Project],
        takenIds: Set<UUID> = [],
        makeId: () -> UUID = UUID.init
    ) -> (created: [ImportedProject], ids: [BundleRef: UUID]) {
        var known = existing.map { Entry(id: $0.id, name: $0.name, sortOrder: $0.sortOrder) }
        var created: [ImportedProject] = []
        var ids: [BundleRef: UUID] = [:]

        for project in planned where ids[project.ref] == nil {
            let name = LibraryProjectName.trimmed(project.name)
            guard !name.isEmpty else { continue }
            if let id = project.id, known.contains(where: { $0.id == id }) {
                ids[project.ref] = id
                continue
            }
            if let match = LibraryProjectName.match(name, in: known) {
                ids[project.ref] = match.id
                continue
            }
            // The file's id is kept, so importing the file again finds this project after a rename.
            let id = project.id.flatMap { takenIds.contains($0) ? nil : $0 } ?? makeId()
            let sortOrder = LibraryOrdering.nextSortOrder(after: known.map(\.sortOrder))
            known.append(Entry(id: id, name: name, sortOrder: sortOrder))
            created.append(ImportedProject(
                id: id,
                name: name,
                color: project.color,
                iconName: LibrarySymbolCatalog.normalizedName(project.iconName),
                sortOrder: sortOrder
            ))
            ids[project.ref] = id
        }
        return (created, ids)
    }
}
