//
//  VersionHistoryModels.swift
//  TablePro
//

import Foundation

internal enum VersionHistorySubject: Codable, Hashable, Sendable {
    case savedQuery(id: UUID)
    case linkedFile(url: URL)
}

internal enum VersionHistoryReference: Hashable, Sendable {
    case current
    case savedQueryVersion(id: Int64)
    case gitRevision(commit: String, path: String)

    var shortRevision: String? {
        guard case .gitRevision(let commit, _) = self else { return nil }
        return String(commit.prefix(7))
    }
}

internal struct VersionHistoryEntry: Identifiable, Hashable, Sendable {
    let reference: VersionHistoryReference
    var summary: String?
    var author: String?
    var date: Date?
    var hasUncommittedChanges = false

    var id: VersionHistoryReference { reference }
    var isCurrent: Bool { reference == .current }
}

internal enum VersionHistoryNotice: Hashable, Sendable {
    case keepsLatestVersions(Int)
    case showsLatestCommits(Int)
}

internal struct VersionHistoryPage: Equatable, Sendable {
    let entries: [VersionHistoryEntry]
    var notice: VersionHistoryNotice?

    static let empty = VersionHistoryPage(entries: [])

    var current: VersionHistoryEntry? {
        entries.first(where: \.isCurrent)
    }

    func baseline(for reference: VersionHistoryReference) -> VersionHistoryEntry? {
        guard reference == .current else { return current }
        return entries.first { !$0.isCurrent }
    }
}

internal enum VersionHistoryError: LocalizedError, Equatable {
    case subjectNotFound
    case versionNotFound
    case gitUnavailable
    case notInRepository
    case noCommitsYet
    case commandFailed(String)
    case undecodableContent
    case storedInLargeFileStorage
    case fileChangedBeforeWriting
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .subjectNotFound:
            return String(localized: "This item no longer exists.")
        case .versionNotFound:
            return String(localized: "This version is no longer available.")
        case .gitUnavailable:
            return String(localized: "Git is not installed. Install the Command Line Tools or Xcode to see file history.")
        case .notInRepository:
            return String(localized: "This file is not in a Git repository.")
        case .noCommitsYet:
            return String(localized: "This repository has no commits yet.")
        case .commandFailed(let message):
            return message
        case .undecodableContent:
            return String(localized: "This version is not readable as text.")
        case .storedInLargeFileStorage:
            return String(localized: "This file is stored with Git LFS. Restore it with your Git client.")
        case .fileChangedBeforeWriting:
            return String(localized: "The file or its staged version changed before it could be written. Nothing was replaced.")
        case .restoreFailed(let message):
            return String(format: String(localized: "The version could not be restored: %@"), message)
        }
    }
}

internal struct VersionRestorePlan: Sendable {
    let replacesUncommittedChanges: Bool
    let apply: @Sendable () async throws -> Void
}

internal protocol VersionHistoryProvider: Sendable {
    func loadHistory() async throws -> VersionHistoryPage
    func content(of reference: VersionHistoryReference) async throws -> String
    func prepareRestore(_ reference: VersionHistoryReference) async throws -> VersionRestorePlan
}
