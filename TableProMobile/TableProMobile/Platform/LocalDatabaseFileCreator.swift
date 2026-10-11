import Foundation
import os
import TableProDatabase
import TableProModels

nonisolated protocol LocalDatabaseFileCreating: Sendable {
    func createDatabase(at url: URL, type: DatabaseType) async throws
    func removeDatabase(at url: URL)
}

nonisolated struct DriverDatabaseFileCreator: LocalDatabaseFileCreating {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LocalDatabaseFileCreator")
    private static let sidecarSuffixes = ["-journal", "-wal", "-shm", ".wal"]

    func createDatabase(at url: URL, type: DatabaseType) async throws {
        let fileName = url.lastPathComponent
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw LocalDatabaseFileError.alreadyExists(fileName: fileName)
        }
        do {
            let driver = try Self.makeDriver(at: url, type: type)
            try await driver.connect()
            try await driver.disconnect()
        } catch {
            removeDatabase(at: url)
            Self.logger.error("Creating a database file failed: \(error.localizedDescription, privacy: .private)")
            throw LocalDatabaseFileError.creationFailed(fileName: fileName, message: error.localizedDescription)
        }
    }

    func removeDatabase(at url: URL) {
        for path in [url.path] + Self.sidecarSuffixes.map({ url.path + $0 }) {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                Self.logger.error("Removing a database file failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private static func makeDriver(at url: URL, type: DatabaseType) throws -> any DatabaseDriver {
        switch type {
        case .sqlite:
            return SQLiteDriver(source: .file(url), openMode: .createNew)
        case .duckdb:
            return DuckDBDriver(source: .file(url), openMode: .createNew)
        default:
            throw ConnectionError.driverNotFound(type.rawValue)
        }
    }
}
