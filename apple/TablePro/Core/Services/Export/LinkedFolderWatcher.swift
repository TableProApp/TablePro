//
//  LinkedFolderWatcher.swift
//  TablePro
//

import Combine
import CryptoKit
import Foundation
import os
import TableProImport

struct LinkedConnection: Identifiable, Sendable {
    let id: UUID
    let connection: ExportableConnection
    let folderId: UUID
    let sourceFileURL: URL
}

struct LinkedFolderStatus: Equatable, Sendable {
    enum Contents: Equatable, Sendable {
        case connections(Int, unreadableFiles: Int)
        case missing
        case unreadable
    }

    let contents: Contents
    let isWatched: Bool
}

struct LinkedFolderScan: Sendable {
    var connections: [LinkedConnection] = []
    var contents: [UUID: LinkedFolderStatus.Contents] = [:]
}

@MainActor
final class LinkedFolderWatcher: ObservableObject {
    static let shared = LinkedFolderWatcher()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "LinkedFolderWatcher")

    @Published private(set) var linkedConnections: [LinkedConnection] = []
    @Published private(set) var folderStatuses: [UUID: LinkedFolderStatus] = [:]
    private var watchSources: [UUID: DispatchSourceFileSystemObject] = [:]
    private var debounceTask: Task<Void, Never>?
    private var hasStarted = false

    private let loadFolders: @MainActor () -> [LinkedFolder]
    private let isFeatureAvailable: @MainActor () -> Bool
    private let scan: @MainActor ([LinkedFolder]) async -> LinkedFolderScan

    init(
        loadFolders: @escaping @MainActor () -> [LinkedFolder] = { LinkedFolderStorage.shared.loadFolders() },
        isFeatureAvailable: @escaping @MainActor () -> Bool = { LicenseManager.shared.isFeatureAvailable(.linkedFolders) },
        scan: @escaping @MainActor ([LinkedFolder]) async -> LinkedFolderScan = { folders in
            await Task.detached(priority: .utility) { LinkedFolderWatcher.scanFolders(folders) }.value
        }
    ) {
        self.loadFolders = loadFolders
        self.isFeatureAvailable = isFeatureAvailable
        self.scan = scan
    }

    func start() {
        guard !hasStarted else { return }
        guard isFeatureAvailable() else { return }
        hasStarted = true
        let folders = loadFolders()
        setupWatchers(for: folders)
        scheduleScan(folders)
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
        debounceTask = Task { [weak self] in
            await self?.runScan(of: folders)
        }
    }

    private func scheduleDebouncedRescan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await runScan(of: loadFolders())
        }
    }

    private func runScan(of folders: [LinkedFolder]) async {
        let result = await scan(folders)
        // A reload cancels this scan; landing anyway would bring back a removed folder's rows.
        guard !Task.isCancelled else { return }
        linkedConnections = result.connections
        folderStatuses = result.contents.reduce(into: [:]) { statuses, entry in
            statuses[entry.key] = LinkedFolderStatus(contents: entry.value, isWatched: watchSources[entry.key] != nil)
        }
        AppEvents.shared.linkedFoldersDidUpdate.send(())
    }

    nonisolated static func scanFolders(_ folders: [LinkedFolder]) -> LinkedFolderScan {
        var scan = LinkedFolderScan()
        var seenIds: Set<UUID> = []
        let fm = FileManager.default

        for folder in folders where folder.isEnabled {
            let expandedPath = folder.expandedPath
            guard fm.fileExists(atPath: expandedPath) else {
                logger.warning("Linked folder not found: \(expandedPath, privacy: .private(mask: .hash))")
                scan.contents[folder.id] = .missing
                continue
            }

            guard let contents = try? fm.contentsOfDirectory(atPath: expandedPath) else {
                logger.warning("Cannot read linked folder: \(expandedPath, privacy: .private(mask: .hash))")
                scan.contents[folder.id] = .unreadable
                continue
            }

            var found = 0
            var unreadable = 0
            for filename in contents where filename.hasSuffix(".tablepro") {
                let fileURL = URL(fileURLWithPath: expandedPath).appendingPathComponent(filename)
                guard let data = try? Data(contentsOf: fileURL) else {
                    logger.warning("Cannot read linked file \(filename, privacy: .private(mask: .hash))")
                    unreadable += 1
                    continue
                }

                // A linked folder has no way to ask for the passphrase.
                guard !ConnectionBundleCodec.isEncrypted(data) else {
                    unreadable += 1
                    continue
                }

                let linkedInFile: [LinkedConnection]
                do {
                    linkedInFile = try linkedConnections(in: data, folderId: folder.id, sourceFileURL: fileURL)
                } catch {
                    logger.warning(
                        "Skipped linked file \(filename, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)"
                    )
                    unreadable += 1
                    continue
                }

                for linked in linkedInFile {
                    guard seenIds.insert(linked.id).inserted else { continue }
                    scan.connections.append(linked)
                    found += 1
                }
            }
            scan.contents[folder.id] = .connections(found, unreadableFiles: unreadable)
        }

        return scan
    }

    // MARK: - Watchers

    private func setupWatchers(for folders: [LinkedFolder]) {
        cancelAllWatchers()

        for folder in folders where folder.isEnabled {
            let expandedPath = folder.expandedPath
            let fd = open(expandedPath, O_EVTONLY)
            guard fd >= 0 else {
                Self.logger.warning("Cannot open linked folder for watching: \(expandedPath, privacy: .private(mask: .hash))")
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename],
                queue: .global(qos: .utility)
            )

            source.setEventHandler { @Sendable [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedRescan()
                }
            }

            source.setCancelHandler { @Sendable in
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

    // A linked row is never saved and asks before it signs in with a credential this Mac holds, so it keeps the
    // selectors a saved import drops.
    nonisolated static func linkedConnections(
        in data: Data,
        folderId: UUID,
        sourceFileURL: URL
    ) throws -> [LinkedConnection] {
        try ConnectionBundleCodec.decode(data, keepingLocalCredentials: true).connections.map {
            linkedConnection(folderId: folderId, sourceFileURL: sourceFileURL, exportable: $0.settings)
        }
    }

    // MARK: - Stable IDs (SHA-256 based, deterministic across launches)

    nonisolated static func linkedConnection(
        folderId: UUID,
        sourceFileURL: URL,
        exportable: ExportableConnection
    ) -> LinkedConnection {
        LinkedConnection(
            id: stableId(folderId: folderId, connection: exportable),
            connection: exportable.withoutTunnelCommand().withoutStartupCommands(),
            folderId: folderId,
            sourceFileURL: sourceFileURL
        )
    }

    nonisolated static func stableId(folderId: UUID, connection: ExportableConnection) -> UUID {
        let fields = [
            connection.name,
            connection.host,
            String(connection.port),
            connection.type,
            connection.database,
            connection.username,
        ]
        return stableId(namespace: folderId, key: fields.joined(separator: "|"))
    }

    nonisolated static func stableId(namespace: UUID, key: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace.uuidString)|\(key)".utf8))
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
