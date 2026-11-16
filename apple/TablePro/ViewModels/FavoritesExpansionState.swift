//
//  FavoritesExpansionState.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
internal final class FavoritesExpansionState: ObservableObject {
    static let shared = FavoritesExpansionState()

    @Published private(set) var foldersByConnection: [UUID: Set<UUID>] = [:]
    @Published private(set) var linkedNodesByConnection: [UUID: Set<String>] = [:]
    @Published private(set) var collapsedDatabaseEnvironmentsByConnection: [UUID: Set<FavoriteDatabaseEnvironment>] = [:]

    private static let foldersKey = JSONDefaultsKey<[UUID: Set<UUID>]>("com.TablePro.favoritesExpandedFolders")
    private static let linkedKey = JSONDefaultsKey<[UUID: Set<String>]>("com.TablePro.favoritesExpandedLinkedNodes")
    // Raw values, so one environment this build does not know drops only itself.
    private static let collapsedDatabaseEnvironmentsKey =
        JSONDefaultsKey<[UUID: Set<String>]>("com.TablePro.favoritesCollapsedDatabaseEnvironments")

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
        load()
    }

    func isFolderExpanded(_ folderId: UUID, for connectionId: UUID) -> Bool {
        foldersByConnection[connectionId, default: []].contains(folderId)
    }

    func isLinkedNodeExpanded(_ nodeId: String, for connectionId: UUID) -> Bool {
        linkedNodesByConnection[connectionId, default: []].contains(nodeId)
    }

    func isDatabaseEnvironmentExpanded(
        _ environment: FavoriteDatabaseEnvironment,
        for connectionId: UUID
    ) -> Bool {
        !collapsedDatabaseEnvironmentsByConnection[connectionId, default: []].contains(environment)
    }

    func setFolderExpanded(_ folderId: UUID, expanded: Bool, for connectionId: UUID) {
        var ids = foldersByConnection[connectionId] ?? []
        if expanded {
            guard !ids.contains(folderId) else { return }
            ids.insert(folderId)
        } else {
            guard ids.contains(folderId) else { return }
            ids.remove(folderId)
        }
        foldersByConnection[connectionId] = ids
        persistFolders()
    }

    func setLinkedNodeExpanded(_ nodeId: String, expanded: Bool, for connectionId: UUID) {
        var ids = linkedNodesByConnection[connectionId] ?? []
        if expanded {
            guard !ids.contains(nodeId) else { return }
            ids.insert(nodeId)
        } else {
            guard ids.contains(nodeId) else { return }
            ids.remove(nodeId)
        }
        linkedNodesByConnection[connectionId] = ids
        persistLinkedNodes()
    }

    func setDatabaseEnvironmentExpanded(
        _ environment: FavoriteDatabaseEnvironment,
        expanded: Bool,
        for connectionId: UUID
    ) {
        var environments = collapsedDatabaseEnvironmentsByConnection[connectionId] ?? []
        if expanded {
            guard environments.contains(environment) else { return }
            environments.remove(environment)
        } else {
            guard !environments.contains(environment) else { return }
            environments.insert(environment)
        }
        collapsedDatabaseEnvironmentsByConnection[connectionId] = environments
        persistCollapsedDatabaseEnvironments()
    }

    func removeConnection(_ connectionId: UUID) {
        foldersByConnection.removeValue(forKey: connectionId)
        linkedNodesByConnection.removeValue(forKey: connectionId)
        collapsedDatabaseEnvironmentsByConnection.removeValue(forKey: connectionId)
        persistFolders()
        persistLinkedNodes()
        persistCollapsedDatabaseEnvironments()
    }

    private func load() {
        if let decoded = defaults.read(Self.foldersKey).value {
            foldersByConnection = decoded
        }
        if let decoded = defaults.read(Self.linkedKey).value {
            linkedNodesByConnection = decoded
        }
        collapsedDatabaseEnvironmentsByConnection = defaults.read(Self.collapsedDatabaseEnvironmentsKey)
            .value.map(Self.knownEnvironments) ?? [:]
    }

    internal static func decodeCollapsedEnvironments(
        _ data: Data?
    ) -> [UUID: Set<FavoriteDatabaseEnvironment>] {
        guard let data,
              let raw = try? collapsedDatabaseEnvironmentsKey.coding.decode([UUID: Set<String>].self, from: data)
        else { return [:] }
        return knownEnvironments(raw)
    }

    nonisolated private static func knownEnvironments(
        _ raw: [UUID: Set<String>]
    ) -> [UUID: Set<FavoriteDatabaseEnvironment>] {
        raw.compactMapValues { values in
            let environments = Set(values.compactMap(FavoriteDatabaseEnvironment.init(rawValue:)))
            return environments.isEmpty ? nil : environments
        }
    }

    private func persistFolders() {
        try? defaults.write(foldersByConnection, to: Self.foldersKey)
    }

    private func persistLinkedNodes() {
        try? defaults.write(linkedNodesByConnection, to: Self.linkedKey)
    }

    private func persistCollapsedDatabaseEnvironments() {
        let raw = collapsedDatabaseEnvironmentsByConnection.mapValues { Set($0.map(\.rawValue)) }
        try? defaults.write(raw, to: Self.collapsedDatabaseEnvironmentsKey)
    }
}
