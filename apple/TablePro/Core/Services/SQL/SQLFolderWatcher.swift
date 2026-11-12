//
//  SQLFolderWatcher.swift
//  TablePro
//

import Combine
import CoreServices
import Foundation
import os

@MainActor
internal final class SQLFolderWatcher: ObservableObject {
    static let shared = SQLFolderWatcher()

    @Published private(set) var lastScanCompletedAt: Date?

    private let eventWatcher = FileSystemEventWatcher(
        latency: 1.0,
        reportsFileEvents: true,
        accepts: { events in
            if SQLFolderWatcher.touchesGitState(events) {
                SQLFolderWatcher.gitStateTouched.withLock { $0 = true }
                return true
            }
            return SQLFolderWatcher.shouldRescan(after: events)
        }
    )
    private var debounceTask: Task<Void, Never>?
    private var hasStarted = false

    // Flags after which the paths in the batch no longer tell what changed.
    nonisolated private static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
    )

    nonisolated static func touchesOnlyRepositoryMetadata(_ paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        return paths.allSatisfy(isRepositoryMetadata)
    }

    // A batch is skipped only when every path is inside `.git` or is a file that cannot be a linked query.
    nonisolated static func shouldRescan(after events: [FileSystemEvent]) -> Bool {
        guard !events.isEmpty else { return true }
        if events.contains(where: { $0.flags & rescanFlags != 0 }) {
            return true
        }
        return !events.allSatisfy { event in
            if isRepositoryMetadata(event.path) {
                return true
            }
            guard event.has(kFSEventStreamEventFlagItemIsFile) else { return false }
            let pathExtension = (event.path as NSString).pathExtension.lowercased()
            return !SQLFileService.supportedExtensions.contains(pathExtension)
        }
    }

    // A repository created or removed here, or an ignore rule edited, changes Git status without touching
    // a query, so the update is sent even when no row changed.
    nonisolated private static let gitStateTouched = OSAllocatedUnfairLock(initialState: false)

    nonisolated static func touchesGitState(_ events: [FileSystemEvent]) -> Bool {
        events.contains { event in
            let name = (event.path as NSString).lastPathComponent
            return name == ".git" || name == ".gitignore"
        }
    }

    nonisolated private static func isRepositoryMetadata(_ path: String) -> Bool {
        path.split(separator: "/").contains(".git")
    }

    private init() {
        eventWatcher.onChange = { [weak self] in self?.scheduleDebouncedRescan() }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let folders = LinkedSQLFolderStorage.shared.loadFolders().filter(\.isEnabled)
        scheduleFullRescan(folders: folders)
        eventWatcher.watch(Set(folders.map(\.expandedURL.path)))
    }

    func stop() {
        eventWatcher.cancel()
        debounceTask?.cancel()
        debounceTask = nil
        hasStarted = false
    }

    func reload() {
        stop()
        start()
    }

    // MARK: - Scan scheduling

    private func scheduleFullRescan(folders: [LinkedSQLFolder]) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            _ = await Self.rescan(folders: folders)
            self?.lastScanCompletedAt = Date()
            AppEvents.shared.linkedSQLFoldersDidUpdate.send(nil)
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
            let changed = await Self.rescan(folders: folders)
            let gitStateTouched = Self.gitStateTouched.withLock { touched in
                defer { touched = false }
                return touched
            }
            self?.lastScanCompletedAt = Date()
            guard changed || gitStateTouched else { return }
            AppEvents.shared.linkedSQLFoldersDidUpdate.send(nil)
        }
    }

    // Returns whether any folder's rows changed or a folder was dropped from the index.
    @concurrent
    nonisolated private static func rescan(folders: [LinkedSQLFolder]) async -> Bool {
        let scanner = LinkedSQLFolderScanner()
        var changed = false
        for folder in folders {
            if await scanner.scan(folderId: folder.id, at: folder.expandedURL) {
                changed = true
            }
        }
        let known = Set(LinkedSQLFolderStorage.shared.loadFolders().map(\.id))
        if await scanner.pruneFolders(keeping: known) {
            changed = true
        }
        return changed
    }
}
