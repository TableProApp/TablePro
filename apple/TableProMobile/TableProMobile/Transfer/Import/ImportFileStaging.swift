import Foundation
import os
import TableProLogRedaction

nonisolated struct StagedImportFile: Sendable, Equatable {
    let url: URL
    let folder: URL
    let originalName: String

    var fileSize: Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber
        return size?.int64Value ?? 0
    }

    func discard() {
        TransferFiles.remove(folder)
    }
}

nonisolated enum ImportFileStagingError: Error, LocalizedError, Equatable {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let message):
            return String(format: String(localized: "Failed to read file: %@"), message)
        }
    }
}

// A picked or opened file can sit in iCloud or another app's provider, and another process may change it under a
// memory map. The import parses a private copy taken under a coordinated read, so neither the security scope nor the
// provider's file has to last across a long or background run (critic M10).
nonisolated enum ImportFileStaging {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportFileStaging")

    @concurrent
    static func stage(_ source: URL, into root: URL = TransferFiles.importsDirectory) async throws -> StagedImportFile {
        let folder = try TransferFiles.makeImportFolder(in: root)
        let name = TransferFiles.sanitizedFileNameKeepingExtension(source.lastPathComponent, fallback: "Import")
        let destination = folder.appendingPathComponent(name, isDirectory: false)
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
        }
        do {
            try coordinatedCopy(from: source, to: destination)
        } catch {
            TransferFiles.remove(folder)
            throw error
        }
        if isInInbox(source) {
            do {
                try FileManager.default.removeItem(at: source)
            } catch {
                logger.warning("Could not remove an opened file from the Inbox: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
        return StagedImportFile(url: destination, folder: folder, originalName: source.lastPathComponent)
    }

    // A coordinated read downloads an iCloud placeholder first and waits for a writer to finish.
    private static func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source, options: [], error: &coordinationError
        ) { readable in
            do {
                try FileManager.default.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            throw ImportFileStagingError.unreadable(error.localizedDescription)
        }
    }

    // A file another app hands over with "Open in" lands in Documents/Inbox, which the app owns and must empty.
    static func isInInbox(_ url: URL) -> Bool {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path
        return url.standardizedFileURL.deletingLastPathComponent().path == inbox
    }
}
