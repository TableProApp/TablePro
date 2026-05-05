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

    @ObservationIgnored private let foldersKey = "com.TablePro.favoritesExpandedFolders"
    @ObservationIgnored private let linkedKey = "com.TablePro.favoritesExpandedLinkedNodes"

    private init() {
        load()
    }

    func isFolderExpanded(_ folderId: UUID, for connectionId: UUID) -> Bool {
        foldersByConnection[connectionId, default: []].contains(folderId)
    }

    func isLinkedNodeExpanded(_ nodeId: String, for connectionId: UUID) -> Bool {
        linkedNodesByConnection[connectionId, default: []].contains(nodeId)
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

    private func load() {
        if let data = UserDefaults.standard.data(forKey: foldersKey),
           let decoded = try? JSONDecoder().decode([UUID: Set<UUID>].self, from: data) {
            foldersByConnection = decoded
        }
        if let data = UserDefaults.standard.data(forKey: linkedKey),
           let decoded = try? JSONDecoder().decode([UUID: Set<String>].self, from: data) {
            linkedNodesByConnection = decoded
        }
    }

    private func persistFolders() {
        if let data = try? JSONEncoder().encode(foldersByConnection) {
            UserDefaults.standard.set(data, forKey: foldersKey)
        }
    }

    private func persistLinkedNodes() {
        if let data = try? JSONEncoder().encode(linkedNodesByConnection) {
            UserDefaults.standard.set(data, forKey: linkedKey)
        }
    }
}
