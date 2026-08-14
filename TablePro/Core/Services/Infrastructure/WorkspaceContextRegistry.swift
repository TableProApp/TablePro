import Foundation
import Observation

// WorkspaceContextRegistry.swift — open-context membership, stable order, MRU selection, activation sequence
// Part of the Database Context Rail feature (Task 2 of the plan).

@MainActor
@Observable
internal final class WorkspaceContextRegistry {
    private var store: WorkspaceContextSnapshotStoring
    private(set) var contexts: [WorkspaceContextDescriptor] = []
    private(set) var selectedKey: WorkspaceContextKey?
    private var keyByWindowId: [UUID: WorkspaceContextKey] = [:]
    private var windowIdsByKey: [WorkspaceContextKey: [UUID]] = [:]
    private var activationSequence: UInt64 = 0
    private var activationHistory: [WorkspaceContextKey] = []

    internal init(store: WorkspaceContextSnapshotStoring = WorkspaceContextSnapshotStore()) {
        self.store = store
        let snapshot = store.load()
        self.contexts = snapshot.orderedKeys.map { WorkspaceContextDescriptor(
            key: $0,
            connectionName: "Unknown",
            databaseType: .mysql,
            connectionColor: .blue,
            isConnected: true
        )}
        self.selectedKey = snapshot.selectedKey
        // Rebuild indexes from loaded state (simplified)
        for key in contexts.map(\.key) {
            windowIdsByKey[key, default: []].forEach { id in
                keyByWindowId[id] = key
            }
        }
    }

    internal func register(windowId: UUID, descriptor: WorkspaceContextDescriptor) {
        contexts.append(descriptor)
        keyByWindowId[windowId] = descriptor.key
        windowIdsByKey[descriptor.key, default: []].append(windowId)
        persist()
    }

    internal func unregister(windowId: UUID) {
        guard let key = keyByWindowId.removeValue(forKey: windowId) else { return }
        windowIdsByKey[key]?.removeAll { $0 == windowId }
        if windowIdsByKey[key]?.isEmpty == true {
            windowIdsByKey.removeValue(forKey: key)
        }
        persist()
    }

    internal func markActive(windowId: UUID) {
        guard let key = keyByWindowId[windowId] else { return }
        activationHistory.append(key)
        activationSequence += 1
        persist()
    }

    internal func beginActivation(for key: WorkspaceContextKey) -> UInt64? {
        guard contains(key) else { return nil }
        activationSequence &+= 1
        return activationSequence
    }

    internal func commitActivation(_ key: WorkspaceContextKey, request: UInt64) -> Bool {
        guard contains(key) && request == activationSequence else { return false }
        selectedKey = key
        persist()
        return true
    }

    internal func windowIds(for key: WorkspaceContextKey) -> [UUID] {
        windowIdsByKey[key] ?? []
    }

    internal func contains(_ key: WorkspaceContextKey) -> Bool {
        windowIdsByKey[key] != nil
    }

    private func persist() {
        let snapshot = WorkspaceContextSnapshot(
            orderedKeys: contexts.map(\.key),
            selectedKey: selectedKey
        )
        (store as? WorkspaceContextSnapshotStore)?.save(snapshot)
    }
}
