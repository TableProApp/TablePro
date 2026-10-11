import Foundation

nonisolated final class LocalDatabaseFileAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var scopedURL: URL?

    func begin(_ source: LocalDatabaseFileSource, openMode: LocalDatabaseOpenMode) throws -> String {
        switch source {
        case .inMemory:
            return LocalDatabaseLocation.inMemoryPath
        case .file(let url):
            try Self.requireFile(at: url, openMode: openMode, reason: .missing)
            return url.path
        case .securityScoped(let url):
            if url.startAccessingSecurityScopedResource() {
                lock.withLock { scopedURL = url }
            }
            do {
                try Self.requireFile(at: url, openMode: openMode, reason: .accessLost)
            } catch {
                end()
                throw error
            }
            return url.path
        }
    }

    func end() {
        let url = lock.withLock { () -> URL? in
            let url = scopedURL
            scopedURL = nil
            return url
        }
        url?.stopAccessingSecurityScopedResource()
    }

    private static func requireFile(
        at url: URL,
        openMode: LocalDatabaseOpenMode,
        reason: LocalDatabaseFileError.UnavailableReason
    ) throws {
        guard openMode == .existingOnly, !FileManager.default.fileExists(atPath: url.path) else { return }
        throw LocalDatabaseFileError.unavailable(fileName: url.lastPathComponent, reason: reason)
    }
}
