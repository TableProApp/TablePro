//
//  SystemContainerNames.swift
//  TablePro
//

import Foundation

internal struct SystemContainerNames: Equatable, Sendable {
    let names: Set<String>
    let ignoresCase: Bool

    static let empty = SystemContainerNames(names: [], ignoresCase: false)

    func contains(_ name: String) -> Bool {
        if names.contains(name) { return true }
        guard ignoresCase else { return false }
        return names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

internal extension PluginManager {
    /// The schema list never had a case-insensitive rule, so only the database list carries the flag.
    func systemContainerNames(for databaseType: DatabaseType, target: ContainerSwitchTarget) -> SystemContainerNames {
        guard let schema = PluginMetadataRegistry.shared.snapshot(for: databaseType)?.schema else { return .empty }
        switch target {
        case .database:
            return SystemContainerNames(
                names: Set(schema.systemDatabaseNames),
                ignoresCase: schema.systemDatabaseNamesIgnoreCase
            )
        case .schema:
            return SystemContainerNames(names: Set(schema.systemSchemaNames), ignoresCase: false)
        }
    }
}
