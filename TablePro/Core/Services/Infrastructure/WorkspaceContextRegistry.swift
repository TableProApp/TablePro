import Combine
import Foundation
import Observation

// WorkspaceContextRegistry.swift — open-context membership, stable order, MRU selection, activation sequence
// Part of the Database Context Rail feature (Task 2 of the plan).

@MainActor
@Observable
internal final class WorkspaceContextRegistry {
    internal static let shared = WorkspaceContextRegistry()

    private var store: WorkspaceContextSnapshotStoring
    private(set) var contexts: [WorkspaceContextDescriptor] = []
    private(set) var selectedKey: WorkspaceContextKey?
    private var keyByWindowId: [UUID: WorkspaceContextKey] = [:]
    private var windowIdsByKey: [WorkspaceContextKey: [UUID]] = [:]
    private var activationSequence: UInt64 = 0
    private var activationHistory: [WorkspaceContextKey] = []
    private var preferredOrder: [WorkspaceContextKey] = []

    internal init(store: WorkspaceContextSnapshotStoring = WorkspaceContextSnapshotStore()) {
        self.store = store
        let snapshot = store.load()
        // Saved keys only restore order. Publishing them as descriptors would invent
        // rail rows with no windows, which violates "only contexts with open tabs".
        self.preferredOrder = snapshot.orderedKeys
        self.selectedKey = snapshot.selectedKey
    }

    internal func register(windowId: UUID, descriptor: WorkspaceContextDescriptor) {
        if let previous = keyByWindowId[windowId], previous != descriptor.key {
            unregister(windowId: windowId)
        }

        keyByWindowId[windowId] = descriptor.key
        var windowIds = windowIdsByKey[descriptor.key] ?? []
        if !windowIds.contains(windowId) {
            windowIds.append(windowId)
            windowIdsByKey[descriptor.key] = windowIds
        }

        // A second window for the same key must reuse the existing rail item.
        if let index = contexts.firstIndex(where: { $0.key == descriptor.key }) {
            contexts[index] = descriptor
        } else {
            insertInPreferredOrder(descriptor)
        }
        persist()
    }

    internal func unregister(windowId: UUID) {
        guard let key = keyByWindowId.removeValue(forKey: windowId) else { return }
        windowIdsByKey[key]?.removeAll { $0 == windowId }
        if windowIdsByKey[key]?.isEmpty != false {
            windowIdsByKey.removeValue(forKey: key)
            removeContext(key)
        }
        persist()
    }

    internal func unregisterAll(for key: WorkspaceContextKey) {
        let windowIds = windowIdsByKey.removeValue(forKey: key) ?? []
        for windowId in windowIds {
            keyByWindowId.removeValue(forKey: windowId)
        }
        removeContext(key)
        persist()
    }

    internal func markActive(windowId: UUID) {
        guard let key = keyByWindowId[windowId] else { return }
        recordActivation(key)
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
        recordActivation(key)
        persist()
        return true
    }

    internal func windowIds(for key: WorkspaceContextKey) -> [UUID] {
        windowIdsByKey[key] ?? []
    }

    internal func contains(_ key: WorkspaceContextKey) -> Bool {
        contexts.contains { $0.key == key }
    }

    private func insertInPreferredOrder(_ descriptor: WorkspaceContextDescriptor) {
        if let preferredIndex = preferredOrder.firstIndex(of: descriptor.key) {
            let insertAt = contexts.firstIndex { existing in
                guard let existingIndex = preferredOrder.firstIndex(of: existing.key) else {
                    return true
                }
                return existingIndex > preferredIndex
            } ?? contexts.endIndex
            contexts.insert(descriptor, at: insertAt)
        } else {
            preferredOrder.append(descriptor.key)
            contexts.append(descriptor)
        }
    }

    private func removeContext(_ key: WorkspaceContextKey) {
        contexts.removeAll { $0.key == key }
        if selectedKey == key {
            selectedKey = mostRecentlyUsedRemaining()
        }
    }

    private func mostRecentlyUsedRemaining() -> WorkspaceContextKey? {
        activationHistory.reversed().first(where: contains) ?? contexts.last?.key
    }

    private func recordActivation(_ key: WorkspaceContextKey) {
        activationHistory.removeAll { $0 == key }
        activationHistory.append(key)
    }

    private func persist() {
        store.save(
            WorkspaceContextSnapshot(
                orderedKeys: contexts.map(\.key),
                selectedKey: selectedKey
            )
        )
        AppEvents.shared.workspaceTabsChanged.send()
    }
}
