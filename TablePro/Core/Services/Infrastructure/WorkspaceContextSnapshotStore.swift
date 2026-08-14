import Foundation

// WorkspaceContextSnapshotStore.swift — lightweight persistence for rail order and selected context
// Part of the Database Context Rail feature (Task 2 of the plan).

internal struct WorkspaceContextSnapshot: Codable, Equatable {
    internal var orderedKeys: [WorkspaceContextKey]
    internal var selectedKey: WorkspaceContextKey?
}

internal protocol WorkspaceContextSnapshotStoring: AnyObject {
    func load() -> WorkspaceContextSnapshot
    func save(_ snapshot: WorkspaceContextSnapshot)
}

internal final class WorkspaceContextSnapshotStore: WorkspaceContextSnapshotStoring {
    private let defaults: UserDefaults
    private let storageKey: String

    internal init(
        defaults: UserDefaults = .standard,
        storageKey: String = "com.TablePro.workspace-contexts"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    internal func load() -> WorkspaceContextSnapshot {
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(WorkspaceContextSnapshot.self, from: data) else {
            return WorkspaceContextSnapshot(orderedKeys: [], selectedKey: nil)
        }
        return snapshot
    }

    internal func save(_ snapshot: WorkspaceContextSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
