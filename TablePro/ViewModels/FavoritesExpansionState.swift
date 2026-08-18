//
//  FavoritesExpansionState.swift
//  TablePro
//

import Foundation
import Observation

@MainActor
@Observable
internal final class FavoritesExpansionState {
    static let shared = FavoritesExpansionState()

    private(set) var foldersByConnection: [UUID: Set<UUID>] = [:]
    private(set) var linkedNodesByConnection: [UUID: Set<String>] = [:]
    private(set) var collapsedDatabaseEnvironmentsByConnection: [UUID: Set<FavoriteDatabaseEnvironment>] = [:]

    @ObservationIgnored private let foldersKey = "com.TablePro.favoritesExpandedFolders"
    @ObservationIgnored private let linkedKey = "com.TablePro.favoritesExpandedLinkedNodes"
    @ObservationIgnored private let collapsedDatabaseEnvironmentsKey =
        "com.TablePro.favoritesCollapsedDatabaseEnvironments"

    private init() {
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
        if let data = AppStorageEnvironment.shared.defaults.data(forKey: foldersKey),
           let decoded = try? JSONDecoder().decode([UUID: Set<UUID>].self, from: data) {
            foldersByConnection = decoded
        }
        if let data = AppStorageEnvironment.shared.defaults.data(forKey: linkedKey),
           let decoded = try? JSONDecoder().decode([UUID: Set<String>].self, from: data) {
            linkedNodesByConnection = decoded
        }
        if let data = AppStorageEnvironment.shared.defaults.data(forKey: collapsedDatabaseEnvironmentsKey),
           let decoded = try? JSONDecoder().decode(
               [UUID: Set<FavoriteDatabaseEnvironment>].self,
               from: data
           ) {
            collapsedDatabaseEnvironmentsByConnection = decoded
        }
    }

    private func persistFolders() {
        if let data = try? JSONEncoder().encode(foldersByConnection) {
            AppStorageEnvironment.shared.defaults.set(data, forKey: foldersKey)
        }
    }

    private func persistLinkedNodes() {
        if let data = try? JSONEncoder().encode(linkedNodesByConnection) {
            AppStorageEnvironment.shared.defaults.set(data, forKey: linkedKey)
        }
    }

    private func persistCollapsedDatabaseEnvironments() {
        if let data = try? JSONEncoder().encode(collapsedDatabaseEnvironmentsByConnection) {
            AppStorageEnvironment.shared.defaults.set(data, forKey: collapsedDatabaseEnvironmentsKey)
        }
    }
}
