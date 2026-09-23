//
//  LinkedFileVersionHistoryProvider.swift
//  TablePro
//

import Foundation

internal struct LinkedFileVersionHistoryProvider: VersionHistoryProvider {
    static let commitLimit = 200
    static let largeFileStoragePointerPrefix = Data("version https://git-lfs.github.com/spec/v1".utf8)

    let fileURL: URL
    var locator: GitExecutableLocator = .system

    private var directory: URL {
        fileURL.deletingLastPathComponent()
    }

    private var indexPath: String {
        "./" + fileURL.lastPathComponent
    }

    func loadHistory() async throws -> VersionHistoryPage {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VersionHistoryError.subjectNotFound
        }
        let client = try makeClient()
        guard let info = try await gitCall({ try await client.repositoryInfo(in: directory) }) else {
            throw VersionHistoryError.notInRepository
        }
        let records = try await gitCall { try await client.status(in: directory, pathspec: fileURL.lastPathComponent) }
        let current = VersionHistoryEntry(
            reference: .current,
            date: FileTextLoader.modificationDate(of: fileURL),
            hasUncommittedChanges: !records.isEmpty
        )
        guard try await gitCall({ try await client.hasCommits(in: directory) }) else {
            return VersionHistoryPage(entries: [current])
        }

        let commits = try await gitCall { try await client.history(of: fileURL, limit: Self.commitLimit + 1) }
        let currentPath = info.prefix + fileURL.lastPathComponent
        let past = commits.prefix(Self.commitLimit).map { commit in
            VersionHistoryEntry(
                reference: .gitRevision(commit: commit.hash, path: commit.path ?? currentPath),
                summary: commit.subject,
                author: commit.author,
                date: commit.date
            )
        }
        return VersionHistoryPage(
            entries: [current] + past,
            notice: commits.count > Self.commitLimit ? .showsLatestCommits(Self.commitLimit) : nil
        )
    }

    func content(of reference: VersionHistoryReference) async throws -> String {
        switch reference {
        case .current:
            guard let loaded = FileTextLoader.load(fileURL) else {
                throw VersionHistoryError.subjectNotFound
            }
            return loaded.content
        case .gitRevision(let commit, let path):
            let client = try makeClient()
            let data = try await gitCall { try await client.blob(revision: commit, path: path, in: directory) }
            guard let content = FileTextLoader.decode(data) else {
                throw VersionHistoryError.undecodableContent
            }
            return content
        case .savedQueryVersion:
            throw VersionHistoryError.versionNotFound
        }
    }

    func prepareRestore(_ reference: VersionHistoryReference) async throws -> VersionRestorePlan {
        guard case .gitRevision(let commit, let path) = reference else {
            throw VersionHistoryError.versionNotFound
        }
        let client = try makeClient()
        let current = try currentBytes()
        let replacement = try await gitCall { try await client.blob(revision: commit, path: path, in: directory) }
        try Self.rejectLargeFileStoragePointer(replacement)
        let replacesUncommittedChanges = try await differsFromLastCommit(current, client: client)
        return writePlan(
            replacing: current,
            with: replacement,
            replacesUncommittedChanges: replacesUncommittedChanges,
            sourceIsUnchanged: { true }
        )
    }

    func prepareDiscard() async throws -> VersionRestorePlan {
        let client = try makeClient()
        let current = try currentBytes()
        let staged = try await gitCall { try await client.blob(revision: "", path: indexPath, in: directory) }
        try Self.rejectLargeFileStoragePointer(staged)
        let directory = directory
        let indexPath = indexPath
        return writePlan(
            replacing: current,
            with: staged,
            replacesUncommittedChanges: true,
            sourceIsUnchanged: { (try? await client.blob(revision: "", path: indexPath, in: directory)) == staged }
        )
    }

    static func rejectLargeFileStoragePointer(_ data: Data) throws {
        guard !data.starts(with: largeFileStoragePointerPrefix) else {
            throw VersionHistoryError.storedInLargeFileStorage
        }
    }

    private func writePlan(
        replacing expected: Data,
        with replacement: Data,
        replacesUncommittedChanges: Bool,
        sourceIsUnchanged: @escaping @Sendable () async -> Bool
    ) -> VersionRestorePlan {
        let fileURL = fileURL
        return VersionRestorePlan(replacesUncommittedChanges: replacesUncommittedChanges) {
            guard await sourceIsUnchanged(), (try? Data(contentsOf: fileURL)) == expected else {
                throw VersionHistoryError.fileChangedBeforeWriting
            }
            do {
                try await SQLFileService.writeData(replacement, to: fileURL)
            } catch {
                throw VersionHistoryError.restoreFailed(error.localizedDescription)
            }
        }
    }

    private func currentBytes() throws -> Data {
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw VersionHistoryError.subjectNotFound
        }
    }

    private func differsFromLastCommit(_ current: Data, client: GitClient) async throws -> Bool {
        let records = try await gitCall { try await client.status(in: directory, pathspec: fileURL.lastPathComponent) }
        guard records.isEmpty else { return true }
        guard try await gitCall({ try await client.hasCommits(in: directory) }) else { return true }
        let committed = try? await client.blob(revision: "HEAD", path: indexPath, in: directory)
        return committed != current
    }

    private func makeClient() throws -> GitClient {
        guard let client = GitClient.make(locator: locator) else {
            throw VersionHistoryError.gitUnavailable
        }
        return client
    }

    private func gitCall<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let failure as GitCommandFailure {
            throw VersionHistoryError.commandFailed(failure.errorDescription ?? failure.message)
        } catch GitProcessError.timedOut {
            throw VersionHistoryError.commandFailed(String(localized: "Git did not respond in time."))
        } catch GitProcessError.outputTooLarge {
            throw VersionHistoryError.commandFailed(String(localized: "The file is too large to read from Git."))
        } catch GitProcessError.launchFailed(let message) {
            throw VersionHistoryError.commandFailed(message)
        }
    }
}
