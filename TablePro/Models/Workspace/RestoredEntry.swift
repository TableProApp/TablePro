//
//  RestoredEntry.swift
//  TablePro
//

import Foundation

/// The connections-strip entry a restore lands in, and the database and schema it switches to.
internal struct RestoredEntry: Equatable {
    internal let container: String?
    internal let database: String?
    internal let schema: String?

    /// A tab a link opened before the restore read the disk is what the user asked for, so its entry
    /// wins. Otherwise the database the connection was last on, which is the entry that was on
    /// screen: the saved selection cannot say so, because an entry with no tab of its own saves the
    /// connection's first tab as selected. The saved tab decides only when no database was saved.
    internal static func resolve(
        selected: QueryTab?,
        isPresent: Bool,
        target: ContainerSwitchTarget?,
        activeDatabase: String?,
        activeSchema: String?
    ) -> RestoredEntry {
        let lastActive = WorkspaceAnchoring.containerName(database: activeDatabase, schema: activeSchema, target: target)
        let saved = RestoredEntry(container: lastActive, database: activeDatabase, schema: activeSchema)
        guard let selected,
              let container = WorkspaceAnchoring.containerName(of: selected, target: target),
              container != lastActive,
              isPresent || lastActive == nil
        else { return saved }
        switch target {
        case .database:
            return RestoredEntry(container: container, database: container, schema: nil)
        case .schema:
            return RestoredEntry(container: container, database: activeDatabase, schema: container)
        case nil:
            return saved
        }
    }
}
