//
//  LinkedFolderGitStatusStore.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import os

internal enum LinkedFileGitState: Equatable, Sendable {
    case clean
    case changed(GitFileStatus)

    var status: GitFileStatus? {
        guard case .changed(let status) = self else { return nil }
        return status
    }

    var hasCommittedHistory: Bool {
        status?.hasCommittedHistory ?? true
    }

    var canDiscardChanges: Bool {
        status?.canDiscardChanges ?? false
    }
}

internal struct LinkedFolderGitSnapshot: Equatable, Sendable {
    let repository: GitRepositoryInfo
    let head: String?
    let statuses: [String: GitFileStatus]
    let trackedPaths: Set<String>

    func state(forRelativePath path: String) -> LinkedFileGitState? {
        if let status = statuses[path] {
            return .changed(status)
        }
        return trackedPaths.contains(path) ? .clean : nil
    }
}

@MainActor
internal final class LinkedFolderGitStatusStore: ObservableObject {
    static let shared = LinkedFolderGitStatusStore()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "LinkedFolderGitStatus")

    @Published private(set) var snapshots: [UUID: LinkedFolderGitSnapshot] = [:]

    private let clientFactory: @Sendable () -> GitClient?
    private let foldersProvider: @MainActor () -> [LinkedSQLFolder]
    private let repositoryWatcher = GitRepositoryWatcher()
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var hasStarted = false

    init(
        clientFactory: @escaping @Sendable () -> GitClient? = { GitClient.make() },
        foldersProvider: @escaping @MainActor () -> [LinkedSQLFolder] = { LinkedSQLFolderStorage.shared.loadFolders() }
    ) {
        self.clientFactory = clientFactory
        self.foldersProvider = foldersProvider
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        AppEvents.shared.linkedSQLFoldersDidUpdate
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        repositoryWatcher.onChange = { [weak self] in self?.scheduleRefresh() }
        scheduleRefresh(after: .zero)
    }

    func state(for favorite: LinkedSQLFavorite) -> LinkedFileGitState? {
        snapshots[favorite.folderId]?.state(forRelativePath: favorite.relativePath)
    }

    func states(for favorites: [LinkedSQLFavorite]) -> [UUID: LinkedFileGitState] {
        var states: [UUID: LinkedFileGitState] = [:]
        for favorite in favorites {
            states[favorite.id] = state(for: favorite)
        }
        return states
    }

    func scheduleRefresh(after delay: Duration = .milliseconds(400)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.refresh()
        }
    }

    func refresh() async {
        let folders = foldersProvider().filter(\.isEnabled)
        let loaded = await Self.loadSnapshots(folders: folders, client: clientFactory(), previous: snapshots)
        guard !Task.isCancelled else { return }
        if loaded != snapshots {
            snapshots = loaded
        }
        repositoryWatcher.watch(Set(loaded.values.map(\.repository.gitDirectory.path)))
    }

    nonisolated static func loadSnapshots(
        folders: [LinkedSQLFolder],
        client: GitClient?,
        previous: [UUID: LinkedFolderGitSnapshot]
    ) async -> [UUID: LinkedFolderGitSnapshot] {
        guard let client else { return [:] }
        var loaded: [UUID: LinkedFolderGitSnapshot] = [:]
        for folder in folders {
            let directory = folder.expandedURL
            do {
                guard let repository = try await client.repositoryInfo(in: directory) else { continue }
                let records = try await client.status(in: directory)
                let tracked = try await client.trackedFiles(in: directory)
                loaded[folder.id] = LinkedFolderGitSnapshot(
                    repository: repository,
                    head: try await client.headCommit(in: directory),
                    statuses: folderRelativeStatuses(records, prefix: repository.prefix),
                    trackedPaths: folderRelativePaths(tracked, prefix: repository.prefix)
                )
            } catch {
                logger.warning("Git status failed for a linked folder: \(error.publicLogShape, privacy: .public)")
                if let kept = previous[folder.id] {
                    loaded[folder.id] = kept
                }
            }
        }
        return loaded
    }

    nonisolated static func folderRelativeStatuses(_ records: [GitStatusRecord], prefix: String) -> [String: GitFileStatus] {
        var statuses: [String: GitFileStatus] = [:]
        for record in records where record.path.hasPrefix(prefix) {
            statuses[String(record.path.dropFirst(prefix.count))] = record.status
        }
        return statuses
    }

    nonisolated static func folderRelativePaths(_ paths: [String], prefix: String) -> Set<String> {
        Set(paths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }
}
