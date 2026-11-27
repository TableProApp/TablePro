import Foundation

public enum LibraryProjectName {
    public enum Problem: Hashable, Sendable {
        case empty
        case duplicate(UUID)
    }

    public static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Composed first, so a name typed on one device and pasted on another gives one key.
    public static func folded(_ name: String) -> String {
        trimmed(name).precomposedStringWithCanonicalMapping.lowercased()
    }

    public static func same(_ lhs: String, _ rhs: String) -> Bool {
        folded(lhs) == folded(rhs)
    }

    public static func problem<Project: LibraryProjectRepresentable>(
        _ name: String,
        among projects: [Project],
        excluding excluded: UUID? = nil
    ) -> Problem? {
        guard !trimmed(name).isEmpty else { return .empty }
        return match(name, in: projects.filter { $0.id != excluded }).map { .duplicate($0.id) }
    }

    // Two devices can each make "Acme" offline, so a name can match more than one: the first in the list order wins.
    public static func match<Project: LibraryProjectRepresentable>(_ name: String, in projects: [Project]) -> Project? {
        let key = folded(name)
        guard !key.isEmpty else { return nil }
        return projects
            .filter { folded($0.name) == key }
            .min { lhs, rhs in
                lhs.sortOrder == rhs.sortOrder ? lhs.id.uuidString < rhs.id.uuidString : lhs.sortOrder < rhs.sortOrder
            }
    }
}
