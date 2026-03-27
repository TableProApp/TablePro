//
//  LinkedFolderStorage.swift
//  TablePro
//
//  UserDefaults persistence for linked folder paths.
//

import Foundation
import os

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
    private static let logger = Logger(subsystem: "com.TablePro", category: "LinkedFolderStorage")
    private let key = "com.TablePro.linkedFolders"

    private init() {}

    func loadFolders() -> [LinkedFolder] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([LinkedFolder].self, from: data)
        } catch {
            Self.logger.error("Failed to decode linked folders: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func saveFolders(_ folders: [LinkedFolder]) {
        do {
            let data = try JSONEncoder().encode(folders)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            Self.logger.error("Failed to encode linked folders: \(error.localizedDescription, privacy: .public)")
        }
    }

    func addFolder(_ folder: LinkedFolder) {
        var folders = loadFolders()
        folders.append(folder)
        saveFolders(folders)
    }

    func removeFolder(_ folder: LinkedFolder) {
        var folders = loadFolders()
        folders.removeAll { $0.id == folder.id }
        saveFolders(folders)
    }
}
