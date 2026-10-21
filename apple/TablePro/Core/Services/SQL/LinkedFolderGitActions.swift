//
//  LinkedFolderGitActions.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import os

internal enum LinkedFolderGitOperation: Equatable, Sendable {
    case commit
    case pull
    case push

    var progressLabel: String {
        switch self {
        case .commit: return String(localized: "Committing…")
        case .pull: return String(localized: "Pulling…")
        case .push: return String(localized: "Pushing…")
        }
    }
}

internal enum LinkedFolderGitError: LocalizedError, Equatable {
    case gitUnavailable
    case notInRepository
    case busy
    case diverged(output: String)
    case failed(output: String)
    case timedOut
    case launchFailed(String)
    case outputTooLarge

    init?(_ error: Error) {
        switch error {
        case is CancellationError:
            return nil
        case let error as LinkedFolderGitError:
            self = error
        case let diverged as GitPullDiverged:
            self = .diverged(output: diverged.output)
        case let failure as GitCommandFailure:
            self = .failed(output: failure.errorDescription ?? failure.message)
        case GitProcessError.timedOut:
            self = .timedOut
        case GitProcessError.outputTooLarge:
            self = .outputTooLarge
        case GitProcessError.launchFailed(let message):
            self = .launchFailed(message)
        default:
            self = .failed(output: error.localizedDescription)
        }
    }

    var errorDescription: String? {
        switch self {
        case .gitUnavailable:
            return String(localized: "Git is not installed. Install the Command Line Tools or Xcode.")
        case .notInRepository:
            return String(localized: "This folder is not in a Git repository.")
        case .busy:
            return String(localized: "Another Git command is still running in this repository.")
        case .diverged:
            return String(localized: "The branch and its upstream branch each have commits the other lacks. Finish this pull in a Git client.")
        case .failed:
            return String(localized: "Git stopped with the message below.")
        case .timedOut:
            return String(localized: "Git did not respond in time.")
        case .launchFailed(let message):
            return message
        case .outputTooLarge:
            return String(localized: "Git printed more output than TablePro can read.")
        }
    }

    var output: String? {
        switch self {
        case .diverged(let output), .failed(let output):
            return output.isEmpty ? nil : output
        default:
            return nil
        }
    }
}

@MainActor
internal final class LinkedFolderGitActions: ObservableObject {
    static let shared = LinkedFolderGitActions()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "LinkedFolderGitActions")

    @Published private(set) var operations: [URL: LinkedFolderGitOperation] = [:]

    private let clientFactory: @Sendable () -> GitClient?
    private let statusStore: LinkedFolderGitStatusStore

    init(
        clientFactory: @escaping @Sendable () -> GitClient? = { GitClient.make() },
        statusStore: LinkedFolderGitStatusStore = .shared
    ) {
        self.clientFactory = clientFactory
        self.statusStore = statusStore
    }

    func operation(for folderId: UUID) -> LinkedFolderGitOperation? {
        guard let topLevel = statusStore.snapshots[folderId]?.repository.topLevel else { return nil }
        return operations[topLevel]
    }

    func pull(_ folder: LinkedSQLFolder) {
        start(
            .pull,
            in: folder,
            announcing: String(format: String(localized: "Pulled \"%@\""), folder.name),
            failureTitle: String(format: String(localized: "Couldn't Pull \"%@\""), folder.name)
        ) {
            try await self.pull(in: $0)
        }
    }

    func push(_ folder: LinkedSQLFolder) {
        start(
            .push,
            in: folder,
            announcing: String(format: String(localized: "Pushed \"%@\""), folder.name),
            failureTitle: String(format: String(localized: "Couldn't Push \"%@\""), folder.name)
        ) {
            try await self.push(in: $0)
        }
    }

    func commit(_ draft: LinkedFolderCommitDraft, in repository: GitRepositoryInfo) async throws {
        try await perform(.commit, in: repository) { client in
            try await client.commit(
                draft.commitPaths,
                adding: draft.untrackedPaths,
                message: draft.message,
                in: repository.topLevel
            )
        }
        AccessibilityAnnouncement.post(String(localized: "Committed"))
    }

    func pull(in repository: GitRepositoryInfo) async throws {
        try await perform(.pull, in: repository) { client in
            let before = try await client.headCommit(in: repository.topLevel)
            try await client.pull(in: repository.topLevel)
            guard let before, let after = try await client.headCommit(in: repository.topLevel), after != before else {
                return
            }
            let changed = try await client.changedPaths(from: before, to: after, in: repository.topLevel)
            await MainActor.run {
                for path in changed {
                    MainContentCoordinator.reloadUnmodifiedFileTabs(at: repository.topLevel.appendingPathComponent(path))
                }
            }
        }
    }

    func push(in repository: GitRepositoryInfo) async throws {
        try await perform(.push, in: repository) { client in
            try await client.push(in: repository.topLevel)
        }
    }

    private func start(
        _ operation: LinkedFolderGitOperation,
        in folder: LinkedSQLFolder,
        announcing announcement: String,
        failureTitle: String,
        _ action: @escaping @MainActor (GitRepositoryInfo) async throws -> Void
    ) {
        guard let repository = statusStore.snapshots[folder.id]?.repository else { return }
        Task {
            do {
                try await action(repository)
                AccessibilityAnnouncement.post(announcement)
            } catch {
                guard let failure = LinkedFolderGitError(error) else { return }
                Self.logger.error("Git \(String(describing: operation), privacy: .public) failed: \(error.publicLogShape, privacy: .public)")
                Self.present(failure, title: failureTitle)
            }
        }
    }

    private func perform(
        _ operation: LinkedFolderGitOperation,
        in repository: GitRepositoryInfo,
        _ body: @escaping @Sendable (GitClient) async throws -> Void
    ) async throws {
        guard let client = clientFactory() else { throw LinkedFolderGitError.gitUnavailable }
        let topLevel = repository.topLevel
        guard operations[topLevel] == nil else { throw LinkedFolderGitError.busy }
        operations[topLevel] = operation
        defer {
            operations[topLevel] = nil
            statusStore.scheduleRefresh(after: .zero)
        }
        try await body(client)
    }

    private static func present(_ failure: LinkedFolderGitError, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = failure.errorDescription ?? ""
        if let output = failure.output {
            alert.accessoryView = AlertHelper.scrollingTextAccessory(output)
        }
        alert.addButton(withTitle: String(localized: "OK"))
        AlertHelper.present(alert, in: nil)
    }
}
