//
//  TeamCatalogStorage.swift
//  TablePro
//
//  Remembers the shared folder used for the team connection catalog.
//

import Foundation

internal enum TeamCatalogStorage {
    private static let folderPathKey = "com.TablePro.teamCatalog.folderPath"

    static var folderURL: URL? {
        get {
            guard let path = AppStorageEnvironment.shared.defaults.string(forKey: folderPathKey), !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
        set {
            if let path = newValue?.path {
                AppStorageEnvironment.shared.defaults.set(path, forKey: folderPathKey)
            } else {
                AppStorageEnvironment.shared.defaults.removeObject(forKey: folderPathKey)
            }
        }
    }
}
