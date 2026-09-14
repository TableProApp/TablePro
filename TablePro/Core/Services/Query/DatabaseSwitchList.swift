import Foundation

struct DatabaseSwitchSections: Equatable {
    let user: [DatabaseMetadata]
    let system: [DatabaseMetadata]

    var all: [DatabaseMetadata] {
        user + system
    }

    var isEmpty: Bool {
        user.isEmpty && system.isEmpty
    }
}

/// What a switcher offers: every database the server listed, with system databases last in their own
/// section.
///
/// A switcher is where a user goes to reach a database by name, so it never hides one the way the
/// sidebar tree does. Hiding them there told a user who typed `mysql` that no such database existed
/// (#2832). The sidebar's database filter still narrows the user databases, because that is the list
/// the filter was made to shorten; it never lists system databases unless the tree shows them, so it
/// does not reach them here.
enum DatabaseSwitchList {
    static func sections(
        databases: [DatabaseMetadata],
        selected: Set<String>,
        activeDatabase: String?
    ) -> DatabaseSwitchSections {
        let active = activeDatabase.flatMap { $0.isEmpty ? nil : $0 }
        let userDatabases = databases.filter { !$0.isSystemDatabase }
        let selection = selected.intersection(userDatabases.map(\.name))
        let user = userDatabases.filter { database in
            selection.isEmpty || selection.contains(database.name) || database.name == active
        }
        return DatabaseSwitchSections(user: user, system: databases.filter(\.isSystemDatabase))
    }

    static func sections(
        names: [String],
        systemNames: Set<String>,
        selected: Set<String>,
        activeDatabase: String?
    ) -> DatabaseSwitchSections {
        let databases = names.map { DatabaseMetadata.minimal(name: $0, isSystem: systemNames.contains($0)) }
        return sections(databases: databases, selected: selected, activeDatabase: activeDatabase)
    }
}
