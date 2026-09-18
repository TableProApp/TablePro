import Foundation
import TableProModels

nonisolated struct LocalDatabaseFileLocator: Sendable {
    static let live = LocalDatabaseFileLocator(container: .live)

    let container: AppContainerPaths
    private let fileExists: @Sendable (String) -> Bool

    var documentsDirectory: URL { container.documentsDirectory }

    init(
        container: AppContainerPaths,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.container = container
        self.fileExists = fileExists
    }

    // MARK: - Reading a stored path

    func location(forStoredPath storedPath: String) -> LocalDatabaseLocation {
        guard storedPath != LocalDatabaseLocation.inMemoryPath else { return .inMemory }
        switch container.resolve(storedPath) {
        case .inThisInstall(let url):
            return .appFile(url)
        case .outsideAppContainers(let url):
            return .externalFile(url)
        case .notOnThisDevice:
            return .notOnThisDevice(storedPath: storedPath)
        }
    }

    func existingSource(for location: LocalDatabaseLocation) throws -> LocalDatabaseFileSource {
        switch location {
        case .inMemory:
            return .inMemory
        case .appFile(let url):
            guard fileExists(url.path) else {
                throw LocalDatabaseFileError.unavailable(fileName: url.lastPathComponent, reason: .missing)
            }
            return .file(url)
        case .externalFile(let url):
            guard fileExists(url.path) else {
                throw LocalDatabaseFileError.unavailable(fileName: url.lastPathComponent, reason: .notOnThisDevice)
            }
            return .file(url)
        case .notOnThisDevice(let storedPath):
            throw LocalDatabaseFileError.unavailable(
                fileName: Self.displayName(of: storedPath),
                reason: .notOnThisDevice
            )
        }
    }

    func isInDocuments(_ url: URL) -> Bool {
        container.isInDocuments(url)
    }

    // MARK: - Adding files to Documents

    func newDatabaseFile(named requestedName: String, type: DatabaseType) throws -> URL {
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else {
            throw LocalDatabaseFileError.invalidName
        }
        let suffix = "." + Self.fileExtension(for: type)
        let fileName = trimmed.hasSuffix(suffix) ? trimmed : trimmed + suffix
        let url = documentsDirectory.appendingPathComponent(fileName)
        guard !fileExists(url.path) else {
            throw LocalDatabaseFileError.alreadyExists(fileName: fileName)
        }
        return url
    }

    func importCopy(of source: URL) throws -> URL {
        let fileName = source.lastPathComponent
        var destination = documentsDirectory.appendingPathComponent(fileName)
        if fileExists(destination.path) {
            destination = documentsDirectory.appendingPathComponent(Self.uniqueName(for: source))
        }
        do {
            try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw LocalDatabaseFileError.copyFailed(fileName: fileName, message: error.localizedDescription)
        }
        return destination
    }

    // MARK: - Names

    private static func displayName(of storedPath: String) -> String {
        let name = (storedPath as NSString).lastPathComponent
        return name.isEmpty ? storedPath : name
    }

    private static func fileExtension(for type: DatabaseType) -> String {
        type == .duckdb ? "duckdb" : "db"
    }

    private static func uniqueName(for source: URL) -> String {
        let baseName = source.deletingPathExtension().lastPathComponent
        let suffix = UUID().uuidString.prefix(8)
        let pathExtension = source.pathExtension
        guard !pathExtension.isEmpty else { return "\(baseName)_\(suffix)" }
        return "\(baseName)_\(suffix).\(pathExtension)"
    }
}
