//
//  SampleDatabaseService.swift
//  TablePro
//

import Foundation
import os

internal enum SampleDatabaseError: Error, LocalizedError, Equatable {
    case bundleMissing
    case copyFailed(message: String)
    case connectionInUse

    internal var errorDescription: String? {
        switch self {
        case .bundleMissing:
            return String(localized: "The bundled sample database is missing from the app.")
        case .copyFailed(let message):
            return String(format: String(localized: "Could not install the sample database: %@"), message)
        case .connectionInUse:
            return String(localized: "Close the open Sample connection before resetting it.")
        }
    }
}

internal protocol SampleDatabaseConnectionInspector {
    func isSampleConnectionOpen(at fileURL: URL) -> Bool
}

@MainActor
internal final class SampleDatabaseService {
    internal static let shared = SampleDatabaseService(
        bundledFileResolver: { Bundle.main.url(forResource: "Chinook", withExtension: "sqlite") },
        connectionInspector: DatabaseManagerSampleConnectionInspector()
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "SampleDatabaseService")

    private let bundledFileResolver: () -> URL?
    private let fileManager: FileManager
    private let connectionInspector: SampleDatabaseConnectionInspector
    private let baseDirectoryProvider: () -> URL

    internal init(
        bundledFileResolver: @escaping () -> URL?,
        fileManager: FileManager = .default,
        connectionInspector: SampleDatabaseConnectionInspector,
        baseDirectoryProvider: @escaping () -> URL = SampleDatabaseService.defaultBaseDirectory
    ) {
        self.bundledFileResolver = bundledFileResolver
        self.fileManager = fileManager
        self.connectionInspector = connectionInspector
        self.baseDirectoryProvider = baseDirectoryProvider
    }

    internal var bundledFileURL: URL? {
        bundledFileResolver()
    }

    internal var installedFileURL: URL {
        baseDirectoryProvider().appendingPathComponent("Chinook.sqlite", isDirectory: false)
    }

    internal func installIfNeeded() throws {
        guard let bundled = bundledFileURL else {
            Self.logger.error("Bundled Chinook.sqlite not found in app bundle")
            throw SampleDatabaseError.bundleMissing
        }

        let installed = installedFileURL
        let directory = installed.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SampleDatabaseError.copyFailed(message: error.localizedDescription)
        }

        if fileManager.fileExists(atPath: installed.path) {
            return
        }

        do {
            try fileManager.copyItem(at: bundled, to: installed)
            Self.logger.info("Installed sample database to \(installed.path, privacy: .public)")
        } catch {
            throw SampleDatabaseError.copyFailed(message: error.localizedDescription)
        }
    }

    internal func resetToBundled() throws {
        guard let bundled = bundledFileURL else {
            throw SampleDatabaseError.bundleMissing
        }

        let installed = installedFileURL
        if connectionInspector.isSampleConnectionOpen(at: installed) {
            throw SampleDatabaseError.connectionInUse
        }

        let directory = installed.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SampleDatabaseError.copyFailed(message: error.localizedDescription)
        }

        if fileManager.fileExists(atPath: installed.path) {
            do {
                try fileManager.removeItem(at: installed)
            } catch {
                throw SampleDatabaseError.copyFailed(message: error.localizedDescription)
            }
        }

        do {
            try fileManager.copyItem(at: bundled, to: installed)
            Self.logger.info("Reset sample database at \(installed.path, privacy: .public)")
        } catch {
            throw SampleDatabaseError.copyFailed(message: error.localizedDescription)
        }
    }

    internal func isSampleConnection(_ connection: DatabaseConnection) -> Bool {
        if connection.isSample { return true }
        guard connection.type == .sqlite else { return false }
        return connection.database.standardizedFileURL == installedFileURL.standardizedFileURL
    }

    nonisolated internal static func defaultBaseDirectory() -> URL {
        let fileManager = FileManager.default
        let appSupport: URL
        do {
            appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            appSupport = fileManager.temporaryDirectory
        }
        return appSupport
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("Samples", isDirectory: true)
    }
}

private struct DatabaseManagerSampleConnectionInspector: SampleDatabaseConnectionInspector {
    func isSampleConnectionOpen(at fileURL: URL) -> Bool {
        MainActor.assumeIsolated {
            DatabaseManager.shared.activeSessions.values.contains { session in
                guard session.connection.type == .sqlite else { return false }
                return session.connection.database.standardizedFileURL == fileURL.standardizedFileURL
            }
        }
    }
}

private extension String {
    var standardizedFileURL: URL {
        URL(fileURLWithPath: self).standardizedFileURL
    }
}
