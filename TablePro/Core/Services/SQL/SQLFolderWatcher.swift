//
//  SQLFolderWatcher.swift
//  TablePro
//

import Combine
import CoreServices
import Foundation
import os

@MainActor
@Observable
internal final class SQLFolderWatcher {
    static let shared = SQLFolderWatcher()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLFolderWatcher")

    private(set) var lastScanCompletedAt: Date?

    @ObservationIgnored private var eventStream: FSEventStreamRef?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    private init() {}

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let folders = LinkedSQLFolderStorage.shared.loadFolders().filter(\.isEnabled)
        scheduleFullRescan(folders: folders)
        setupEventStream(for: folders)
    }

    func stop() {
        cancelEventStream()
        debounceTask?.cancel()
        debounceTask = nil
        hasStarted = false
    }

    func reload() {
        stop()
        start()
    }

    // MARK: - Event stream

    private func setupEventStream(for folders: [LinkedSQLFolder]) {
        cancelEventStream()
        guard !folders.isEmpty else { return }

        let paths = folders.map(\.expandedURL.path) as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<SQLFolderWatcher>.fromOpaque(info).takeUnretainedValue()
                Task { @MainActor in
                    watcher.scheduleDebouncedRescan()
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else {
            Self.logger.error("Failed to create FSEventStream")
            return
        }

        FSEventStreamSetDispatchQueue(stream, .global(qos: .utility))
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func cancelEventStream() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    // MARK: - Scan scheduling

    private func scheduleFullRescan(folders: [LinkedSQLFolder]) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            await Self.rescan(folders: folders)
            self?.lastScanCompletedAt = Date()
            AppEvents.shared.linkedSQLFoldersDidUpdate.send(())
        }
    }

    private func scheduleDebouncedRescan() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            let folders = LinkedSQLFolderStorage.shared.loadFolders().filter(\.isEnabled)
            await Self.rescan(folders: folders)
            self?.lastScanCompletedAt = Date()
            AppEvents.shared.linkedSQLFoldersDidUpdate.send(())
        }
    }

    private static func rescan(folders: [LinkedSQLFolder]) async {
        await Task.detached(priority: .utility) {
            for folder in folders {
                await scanFolder(folder)
            }
            let allKnownIds = Set(LinkedSQLFolderStorage.shared.loadFolders().map(\.id))
            await pruneRemovedFolders(stillKnownIds: allKnownIds)
        }.value
    }

    // MARK: - Per-folder scan (background)

    private static func scanFolder(_ folder: LinkedSQLFolder) async {
        let folderURL = folder.expandedURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: folderURL.path) else {
            await LinkedSQLIndex.shared.removeFolder(folderId: folder.id)
            return
        }

        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var indexed: [LinkedSQLIndex.IndexedFile] = []

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "sql" else { continue }

            let resourceValues = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .contentModificationDateKey, .fileSizeKey
            ])
            guard resourceValues?.isRegularFile == true else { continue }
            let mtime = resourceValues?.contentModificationDate ?? Date()
            let fileSize = Int64(resourceValues?.fileSize ?? 0)

            guard let relativePath = relativePathFor(url: url, base: folderURL) else { continue }
            let header = FileTextLoader.loadHeader(url)
            let metadata = header.map { SQLFrontmatter.parse($0.content) } ?? SQLFrontmatter.Metadata()
            let encoding = header?.encoding ?? .utf8

            let baseName = (url.lastPathComponent as NSString).deletingPathExtension
            let displayName = metadata.name?.trimmingCharacters(in: .whitespaces).nonEmpty
                ?? baseName

            indexed.append(LinkedSQLIndex.IndexedFile(
                relativePath: relativePath,
                name: displayName,
                keyword: metadata.keyword,
                description: metadata.description,
                mtime: mtime,
                fileSize: fileSize,
                encoding: encoding
            ))
        }

        await LinkedSQLIndex.shared.replaceAll(folderId: folder.id, files: indexed, folderURL: folderURL)
    }

    private static func pruneRemovedFolders(stillKnownIds: Set<UUID>) async {
        let indexedIds = await LinkedSQLIndex.shared.allFolderIds()
        let stale = indexedIds.subtracting(stillKnownIds)
        for id in stale {
            await LinkedSQLIndex.shared.removeFolder(folderId: id)
        }
    }

    private static func relativePathFor(url: URL, base: URL) -> String? {
        let urlPath = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        guard urlPath.hasPrefix(basePath + "/") else { return nil }
        return String(urlPath.dropFirst(basePath.count + 1))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
