import Foundation
import Testing

/// A defaults suite that lives and dies with its owner. The suite is named by a path in a temporary
/// directory, so its plist lands there: a named suite leaves a 42-byte plist in
/// ~/Library/Preferences, which cfprefsd writes back seconds after the file is deleted.
final class EphemeralDefaults {
    let defaults: UserDefaults
    let suiteName: String
    private let directory: URL

    init(_ label: String = #fileID) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EphemeralDefaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = directory
            .appendingPathComponent(label.replacingOccurrences(of: "/", with: "."), isDirectory: false)
            .path
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// For a factory that makes a fresh suite on every call: each one lives as long as the pool.
final class EphemeralDefaultsPool {
    private var suites: [EphemeralDefaults] = []

    func make(_ label: String = #fileID) throws -> EphemeralDefaults {
        let suite = try EphemeralDefaults(label)
        suites.append(suite)
        return suite
    }
}
