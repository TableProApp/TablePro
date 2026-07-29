//
//  LinkedFolderStorage.swift
//  TablePro
//

import Foundation
import TableProImport

struct LinkedFolder: Codable, Identifiable, Hashable {
    let id: UUID
    var path: String
    var isEnabled: Bool

    var name: String { (path as NSString).lastPathComponent }
    var expandedPath: String { PathPortability.expandHome(path) }

    init(id: UUID = UUID(), path: String, isEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.isEnabled = isEnabled
    }
}

final class LinkedFolderStorage {
    static let shared = LinkedFolderStorage()

    private let store: CodableListPreferenceStore<LinkedFolder>

    init(defaults: KeyValueStore = UserDefaults.standard) {
        store = CodableListPreferenceStore(key: PreferenceKeys.linkedFolders, store: defaults)
    }

    func loadFolders() -> [LinkedFolder] {
        store.load()
    }

    func saveFolders(_ folders: [LinkedFolder]) {
        store.save(folders)
    }

    func addFolder(_ folder: LinkedFolder) {
        store.add(folder)
    }

    func removeFolder(_ folder: LinkedFolder) {
        store.remove(id: folder.id)
    }
}
