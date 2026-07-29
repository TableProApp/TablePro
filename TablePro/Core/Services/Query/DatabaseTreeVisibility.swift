import Foundation

enum DatabaseTreeVisibility {
    static func visible(
        databases: [DatabaseMetadata],
        selected: Set<String>,
        activeDatabase: String?
    ) -> [DatabaseMetadata] {
        let active = activeDatabase.flatMap { $0.isEmpty ? nil : $0 }
        return databases.filter { database in
            if database.name == active { return true }
            guard !database.isSystemDatabase else { return false }
            return selected.isEmpty || selected.contains(database.name)
        }
    }

    static func isFiltering(selected: Set<String>) -> Bool {
        !selected.isEmpty
    }
}
