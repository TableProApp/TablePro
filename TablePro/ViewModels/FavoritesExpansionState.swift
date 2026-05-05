//
//  FavoritesExpansionState.swift
//  TablePro
//

import Foundation
import Observation

internal extension Notification.Name {
    static let favoritesExpansionDidChange = Notification.Name("com.TablePro.favoritesExpansionDidChange")
}

@MainActor
@Observable
internal final class FavoritesExpansionState {
    static let shared = FavoritesExpansionState()

    @ObservationIgnored private var foldersByConnection: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var linkedNodesByConnection: [UUID: Set<String>] = [:]
    @ObservationIgnored private let foldersKey = "com.TablePro.favoritesExpandedFolders"
    @ObservationIgnored private let linkedKey = "com.TablePro.favoritesExpandedLinkedNodes"

    private init() {
        load()
    }

    func expandedFolders(for connectionId: UUID) -> Set<UUID> {
        foldersByConnection[connectionId] ?? []
    }

    func expandedLinkedNodes(for connectionId: UUID) -> Set<String> {
        linkedNodesByConnection[connectionId] ?? []
    }

    func setFolderExpanded(_ folderId: UUID, expanded: Bool, for connectionId: UUID) {
        var ids = foldersByConnection[connectionId] ?? []
        if expanded {
            ids.insert(folderId)
        } else {
            ids.remove(folderId)
        }
        foldersByConnection[connectionId] = ids
        persist()
        notify()
    }

    func setLinkedNodeExpanded(_ nodeId: String, expanded: Bool, for connectionId: UUID) {
        var ids = linkedNodesByConnection[connectionId] ?? []
        if expanded {
            ids.insert(nodeId)
        } else {
            ids.remove(nodeId)
        }
        linkedNodesByConnection[connectionId] = ids
        persist()
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .favoritesExpansionDidChange, object: nil)
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

    private func persist() {
        if let data = try? JSONEncoder().encode(foldersByConnection) {
            UserDefaults.standard.set(data, forKey: foldersKey)
        }
        if let data = try? JSONEncoder().encode(linkedNodesByConnection) {
            UserDefaults.standard.set(data, forKey: linkedKey)
        }
    }
}
