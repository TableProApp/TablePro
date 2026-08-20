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

    @ObservationIgnored private let defaults: UserDefaults

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
        if let data = defaults.data(forKey: foldersKey),
           let decoded = try? JSONDecoder().decode([UUID: Set<UUID>].self, from: data) {
            foldersByConnection = decoded
        }
        if let data = defaults.data(forKey: linkedKey),
           let decoded = try? JSONDecoder().decode([UUID: Set<String>].self, from: data) {
            linkedNodesByConnection = decoded
        }
        collapsedDatabaseEnvironmentsByConnection = Self.decodeCollapsedEnvironments(
            defaults.data(forKey: collapsedDatabaseEnvironmentsKey)
        )
    }

    /// Decoded per raw value rather than whole. `Set<FavoriteDatabaseEnvironment>` fails the entire
    /// payload on one case this build does not know, which would silently discard the collapsed
    /// state of every group of every connection, permanently, from the next write onward.
    internal static func decodeCollapsedEnvironments(
        _ data: Data?
    ) -> [UUID: Set<FavoriteDatabaseEnvironment>] {
        guard let data,
              let raw = try? JSONDecoder().decode([UUID: Set<String>].self, from: data)
        else { return [:] }
        return raw.compactMapValues { values in
            let environments = Set(values.compactMap(FavoriteDatabaseEnvironment.init(rawValue:)))
            return environments.isEmpty ? nil : environments
        }
    }

    private func persistFolders() {
        if let data = try? JSONEncoder().encode(foldersByConnection) {
            defaults.set(data, forKey: foldersKey)
        }
    }

    private func persistLinkedNodes() {
        if let data = try? JSONEncoder().encode(linkedNodesByConnection) {
            defaults.set(data, forKey: linkedKey)
        }
    }

    private func persistCollapsedDatabaseEnvironments() {
        let raw = collapsedDatabaseEnvironmentsByConnection.mapValues { Set($0.map(\.rawValue)) }
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: collapsedDatabaseEnvironmentsKey)
        }
    }
}
