//
//  QueryTabVersionHistoryProvider.swift
//  TablePro
//

import Foundation

internal struct LiveQueryTab: Sendable, Equatable {
    let connectionId: UUID
    let text: String
}

internal struct QueryTabVersionHistoryProvider: VersionHistoryProvider {
    let tabId: UUID
    let storage: QueryTabVersionStorage
    // Nil once the tab is closed.
    let liveTab: @MainActor @Sendable () -> LiveQueryTab?
    // False when the tab is gone by the time the text arrives.
    let write: @MainActor @Sendable (String) -> Bool
    var isCapturePaused: @MainActor @Sendable () -> Bool = { QueryHistoryCaptureStore.isPaused }

    func loadHistory() async throws -> VersionHistoryPage {
        guard await liveTab() != nil else { throw VersionHistoryError.tabClosed }
        let past = storage.summaries(tabId: tabId).map { Self.entry(for: $0) }
        return VersionHistoryPage(
            entries: [VersionHistoryEntry(reference: .current)] + past,
            notice: .keepsRecentVersions(count: QueryTabVersionStorage.retainedVersionCount, days: storage.retentionDays)
        )
    }

    func content(of reference: VersionHistoryReference) async throws -> String {
        switch reference {
        case .current:
            guard let live = await liveTab() else { throw VersionHistoryError.tabClosed }
            return live.text
        case .tabVersion(let id):
            guard let version = storage.version(id: id, tabId: tabId) else {
                throw VersionHistoryError.versionNotFound
            }
            return version.query
        case .savedQueryVersion, .gitRevision:
            throw VersionHistoryError.versionNotFound
        }
    }

    // Restore is recoverable through the version it records first, since the target editor is rarely mounted.
    func prepareRestore(_ reference: VersionHistoryReference) async throws -> VersionRestorePlan {
        guard case .tabVersion(let id) = reference, let version = storage.version(id: id, tabId: tabId) else {
            throw VersionHistoryError.versionNotFound
        }
        guard await liveTab() != nil else { throw VersionHistoryError.tabClosed }
        return VersionRestorePlan(replacesUncommittedChanges: false) {
            guard let live = await liveTab() else { throw VersionHistoryError.tabClosed }
            if await !isCapturePaused() {
                await storage.record(
                    tabId: tabId,
                    connectionId: live.connectionId,
                    text: live.text,
                    reason: .beforeRestore
                )
            }
            guard await write(version.query) else { throw VersionHistoryError.tabClosed }
        }
    }

    static func entry(for summary: QueryTabVersionSummary) -> VersionHistoryEntry {
        VersionHistoryEntry(
            reference: .tabVersion(id: summary.id),
            summary: summary.reason.summary,
            date: summary.savedAt
        )
    }
}

extension QueryTabVersionReason {
    // An idle snapshot has no label, so its title is its date.
    var summary: String? {
        switch self {
        case .run: String(localized: "Run")
        case .idle: nil
        case .beforeReplace: String(localized: "Before Replace")
        case .beforeRestore: String(localized: "Before Restore")
        }
    }
}
