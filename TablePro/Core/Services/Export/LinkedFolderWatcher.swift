//
//  LinkedFolderWatcher.swift
//  TablePro
//
//  Watches linked folders for .tablepro connection files.
//  Rescans on filesystem changes with 1s debounce.
//

import Combine
import CryptoKit
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
    private var debounceTask: Task<Void, Never>?
    private var hasStarted = false

    private init() {}

    func start() {
        guard !hasStarted else { return }
        guard LicenseManager.shared.isFeatureAvailable(.linkedFolders) else { return }
        hasStarted = true
        let folders = LinkedFolderStorage.shared.loadFolders()
        scheduleScan(folders)
        setupWatchers(for: folders)
    }

    func stop() {
        cancelAllWatchers()
        debounceTask?.cancel()
        debounceTask = nil
        hasStarted = false
    }

    func reload() {
        stop()
        start()
    }

    // MARK: - Scanning (off main thread)

    private func scheduleScan(_ folders: [LinkedFolder]) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            let results = await Self.scanFoldersAsync(folders)
            self?.linkedConnections = results
            AppEvents.shared.linkedFoldersDidUpdate.send(())
        }
    }

    private func scheduleDebouncedRescan() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let folders = LinkedFolderStorage.shared.loadFolders()
            let results = await Self.scanFoldersAsync(folders)
            self?.linkedConnections = results
            AppEvents.shared.linkedFoldersDidUpdate.send(())
        }
    }

    /// Scans folders on a background thread to avoid blocking the main actor.
    nonisolated private static func scanFoldersAsync(_ folders: [LinkedFolder]) async -> [LinkedConnection] {
        await Task.detached(priority: .utility) {
            scanFolders(folders)
        }.value
    }

    /// Pure scanning logic. Runs on any thread.
    nonisolated private static func scanFolders(_ folders: [LinkedFolder]) -> [LinkedConnection] {
        var results: [LinkedConnection] = []
        let fm = FileManager.default

        for folder in folders where folder.isEnabled {
            let expandedPath = folder.expandedPath
            guard fm.fileExists(atPath: expandedPath) else {
                logger.warning("Linked folder not found: \(expandedPath, privacy: .public)")
                continue
            }

            guard let contents = try? fm.contentsOfDirectory(atPath: expandedPath) else {
                logger.warning("Cannot read linked folder: \(expandedPath, privacy: .public)")
                continue
            }

            for filename in contents where filename.hasSuffix(".tablepro") {
                let fileURL = URL(fileURLWithPath: expandedPath).appendingPathComponent(filename)
                guard let data = try? Data(contentsOf: fileURL) else { continue }

                if ConnectionExportCrypto.isEncrypted(data) { continue }

                guard let envelope = try? ConnectionExportService.decodeData(data) else { continue }

                for exportable in envelope.connections {
                    let stableId = stableId(folderId: folder.id, connection: exportable)
                    results.append(LinkedConnection(
                        id: stableId,
                        connection: exportable,
                        folderId: folder.id,
                        sourceFileURL: fileURL
                    ))
                }
            }
        }

        return results
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
        for (_, source) in watchSources {
            source.cancel()
        }
        watchSources.removeAll()
    }

    // MARK: - Stable IDs (SHA-256 based, deterministic across launches)

    nonisolated private static func stableId(folderId: UUID, connection: ExportableConnection) -> UUID {
        let key = "\(folderId.uuidString)|\(connection.name)|\(connection.host)|\(connection.port)|\(connection.type)"
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        // Set UUID version 5 and variant bits
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
