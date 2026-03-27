//
//  LinkedFolderWatcher.swift
//  TablePro
//
//  Watches linked folders for .tablepro connection files.
//  Rescans on filesystem changes with 1s debounce.
//

import Foundation
import os

struct LinkedConnection: Identifiable {
    let id: UUID
    let connection: ExportableConnection
    let folderId: UUID
    let sourceFileURL: URL
}

@MainActor
@Observable
final class LinkedFolderWatcher {
    static let shared = LinkedFolderWatcher()
    private static let logger = Logger(subsystem: "com.TablePro", category: "LinkedFolderWatcher")

    private(set) var linkedConnections: [LinkedConnection] = []
    private var watchSources: [UUID: DispatchSourceFileSystemObject] = [:]
    private var fileDescriptors: [UUID: Int32] = [:]
    private var debounceTask: Task<Void, Never>?

    private init() {}

    func start() {
        let folders = LinkedFolderStorage.shared.loadFolders()
        scanAllFolders(folders)
        setupWatchers(for: folders)
    }

    func stop() {
        cancelAllWatchers()
        debounceTask?.cancel()
        debounceTask = nil
    }

    func reload() {
        stop()
        start()
    }

    // MARK: - Scanning

    private func scanAllFolders(_ folders: [LinkedFolder]) {
        var results: [LinkedConnection] = []
        let fm = FileManager.default

        for folder in folders where folder.isEnabled {
            let expandedPath = folder.expandedPath
            guard fm.fileExists(atPath: expandedPath) else {
                Self.logger.warning("Linked folder not found: \(expandedPath, privacy: .public)")
                continue
            }

            guard let contents = try? fm.contentsOfDirectory(atPath: expandedPath) else {
                Self.logger.warning("Cannot read linked folder: \(expandedPath, privacy: .public)")
                continue
            }

            for filename in contents where filename.hasSuffix(".tablepro") {
                let fileURL = URL(fileURLWithPath: expandedPath).appendingPathComponent(filename)
                guard let data = try? Data(contentsOf: fileURL) else { continue }

                // Skip encrypted files
                if ConnectionExportCrypto.isEncrypted(data) { continue }

                guard let envelope = try? ConnectionExportService.decodeData(data) else { continue }

                for exportable in envelope.connections {
                    let stableId = Self.stableId(folderId: folder.id, connection: exportable)
                    results.append(LinkedConnection(
                        id: stableId,
                        connection: exportable,
                        folderId: folder.id,
                        sourceFileURL: fileURL
                    ))
                }
            }
        }

        linkedConnections = results
        NotificationCenter.default.post(name: .linkedFoldersDidUpdate, object: nil)
    }

    // MARK: - Watchers

    private func setupWatchers(for folders: [LinkedFolder]) {
        cancelAllWatchers()

        for folder in folders where folder.isEnabled {
            let expandedPath = folder.expandedPath
            let fd = open(expandedPath, O_EVTONLY)
            guard fd >= 0 else {
                Self.logger.warning("Cannot open linked folder for watching: \(expandedPath, privacy: .public)")
                continue
            }

            fileDescriptors[folder.id] = fd

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename],
                queue: .global(qos: .utility)
            )

            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedRescan()
                }
            }

            source.setCancelHandler {
                close(fd)
            }

            watchSources[folder.id] = source
            source.resume()
        }
    }

    private func cancelAllWatchers() {
        for (folderId, source) in watchSources {
            source.cancel()
            fileDescriptors.removeValue(forKey: folderId)
        }
        watchSources.removeAll()
    }

    private func scheduleDebouncedRescan() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let folders = LinkedFolderStorage.shared.loadFolders()
            self?.scanAllFolders(folders)
        }
    }

    // MARK: - Stable IDs

    /// Generates a deterministic UUID from folder ID + connection identity fields.
    /// This keeps SwiftUI list identity stable across rescans.
    private nonisolated static func stableId(folderId: UUID, connection: ExportableConnection) -> UUID {
        var hasher = Hasher()
        hasher.combine(folderId)
        hasher.combine(connection.name)
        hasher.combine(connection.host)
        hasher.combine(connection.port)
        hasher.combine(connection.type)
        let hash = hasher.finalize()

        // Convert hash to a deterministic UUID by using the hash bits
        var bytes = withUnsafeBytes(of: hash) { Array($0) }
        // Pad to 16 bytes
        while bytes.count < 16 { bytes.append(0) }
        // Incorporate folderId bytes for additional uniqueness
        let folderBytes = withUnsafeBytes(of: folderId.uuid) { Array($0) }
        for i in 0..<min(bytes.count, folderBytes.count) {
            bytes[i] ^= folderBytes[i]
        }

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
