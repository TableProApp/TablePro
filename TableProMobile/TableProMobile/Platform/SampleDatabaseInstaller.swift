import Foundation
import os

nonisolated enum SampleDatabaseError: LocalizedError, Equatable {
    case bundleMissing
    case copyFailed(message: String)
    case libraryUnavailable

    var errorDescription: String? {
        switch self {
        case .bundleMissing:
            return String(localized: "The sample database is missing from the app.")
        case .copyFailed(let message):
            return String(format: String(localized: "Could not install the sample database: %@"), message)
        case .libraryUnavailable:
            return String(localized: "Your connections could not be loaded, so nothing can be added right now.")
        }
    }
}

nonisolated struct SampleDatabaseInstaller: Sendable {
    static let fileName = "Chinook.sqlite"
    static let startingTable = "Track"
    static let sidecarSuffixes = ["-journal", "-wal", "-shm"]

    static var connectionName: String {
        String(localized: "Chinook (Sample)")
    }

    static let live = SampleDatabaseInstaller(
        bundledURL: Bundle.main.url(forResource: "Chinook", withExtension: "sqlite"),
        directory: defaultDirectory
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "SampleDatabase")

    let bundledURL: URL?
    let directory: URL

    var installedURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    @discardableResult
    func installIfNeeded() throws -> URL {
        let installed = installedURL
        guard !FileManager.default.fileExists(atPath: installed.path) else { return installed }
        try removeSidecars(of: installed)
        try copyBundledFile(to: installed)
        Self.logger.info("Installed the sample database")
        return installed
    }

    @discardableResult
    func reset() throws -> URL {
        let installed = installedURL
        try removeItemIfPresent(at: installed)
        try removeSidecars(of: installed)
        try copyBundledFile(to: installed)
        Self.logger.info("Reset the sample database")
        return installed
    }

    private func removeSidecars(of database: URL) throws {
        for suffix in Self.sidecarSuffixes {
            try removeItemIfPresent(at: URL(fileURLWithPath: database.path + suffix))
        }
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw SampleDatabaseError.copyFailed(message: error.localizedDescription)
        }
    }

    private func copyBundledFile(to destination: URL) throws {
        guard let bundledURL else {
            Self.logger.error("Chinook.sqlite is not in the app bundle")
            throw SampleDatabaseError.bundleMissing
        }
        do {
            try prepareDirectory()
            try FileManager.default.copyItem(at: bundledURL, to: destination)
        } catch {
            throw SampleDatabaseError.copyFailed(message: error.localizedDescription)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try excluded.setResourceValues(values)
    }

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("TableProMobile", isDirectory: true)
            .appendingPathComponent("Samples", isDirectory: true)
    }
}
