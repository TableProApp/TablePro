//
//  TeamLibraryMetadataStorage.swift
//  TablePro
//
//  Remembers when the team library was last pulled so the app refreshes on the license revalidation
//  cadence rather than on every launch.
//

import Foundation

enum TeamLibraryMetadataStorage {
    private static let lastPullKey = "com.TablePro.teamLibrary.lastPullAt"
    private static let pullInterval: TimeInterval = 7 * 24 * 60 * 60

    static var lastPullAt: Date? {
        let timestamp = UserDefaults.standard.double(forKey: lastPullKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    static var isPullDue: Bool {
        guard let lastPullAt else { return true }
        return Date().timeIntervalSince(lastPullAt) >= pullInterval
    }

    static func recordPull() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastPullKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: lastPullKey)
    }
}
