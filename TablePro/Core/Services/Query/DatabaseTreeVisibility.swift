import Foundation

enum DatabaseTreeVisibility {
    static func visible(databases: [DatabaseMetadata], selected: Set<String>) -> [DatabaseMetadata] {
        let nonSystem = databases.filter { !$0.isSystemDatabase }
        guard !selected.isEmpty else { return nonSystem }
        return nonSystem.filter { selected.contains($0.name) }
    }

    static func isFiltering(selected: Set<String>) -> Bool {
        !selected.isEmpty
    }
}
