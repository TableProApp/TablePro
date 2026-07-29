//
//  LinkedSQLFolderStorage.swift
//  TablePro
//

import Foundation

internal final class LinkedSQLFolderStorage: @unchecked Sendable {
    static let shared = LinkedSQLFolderStorage()

    private let store: CodableListPreferenceStore<LinkedSQLFolder>

    init(defaults: KeyValueStore = UserDefaults.standard) {
        store = CodableListPreferenceStore(key: PreferenceKeys.linkedSQLFolders, store: defaults)
    }

    func loadFolders() -> [LinkedSQLFolder] {
        store.load()
    }

    func saveFolders(_ folders: [LinkedSQLFolder]) {
        store.save(folders)
    }

    func addFolder(_ folder: LinkedSQLFolder) {
        store.add(folder)
    }

    func removeFolder(_ folder: LinkedSQLFolder) {
        store.remove(id: folder.id)
    }

    func updateFolder(_ folder: LinkedSQLFolder) {
        store.update(folder)
    }
}
