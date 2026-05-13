//
//  LinkedSQLFolderStorage.swift
//  TablePro
//

import Foundation
import os

internal final class LinkedSQLFolderStorage: @unchecked Sendable {
    static let shared = LinkedSQLFolderStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "LinkedSQLFolderStorage")
    private let key = "com.TablePro.linkedSQLFolders"

    private init() {}

    func loadFolders() -> [LinkedSQLFolder] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([LinkedSQLFolder].self, from: data)
        } catch {
            Self.logger.error("Failed to decode linked SQL folders: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func saveFolders(_ folders: [LinkedSQLFolder]) {
        do {
            let data = try JSONEncoder().encode(folders)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            Self.logger.error("Failed to encode linked SQL folders: \(error.localizedDescription, privacy: .public)")
        }
    }

    func addFolder(_ folder: LinkedSQLFolder) {
        var folders = loadFolders()
        folders.append(folder)
        saveFolders(folders)
    }

    func removeFolder(_ folder: LinkedSQLFolder) {
        var folders = loadFolders()
        folders.removeAll { $0.id == folder.id }
        saveFolders(folders)
    }

    func updateFolder(_ folder: LinkedSQLFolder) {
        var folders = loadFolders()
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index] = folder
        saveFolders(folders)
    }
}
