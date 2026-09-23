//
//  SavedQueryVersionHistoryProvider.swift
//  TablePro
//

import Foundation

internal struct SavedQueryVersionHistoryProvider: VersionHistoryProvider {
    let favoriteId: UUID
    let manager: SQLFavoriteManager

    func loadHistory() async throws -> VersionHistoryPage {
        guard let favorite = await manager.fetchFavorite(id: favoriteId) else {
            throw VersionHistoryError.subjectNotFound
        }
        let versions = await manager.fetchVersions(favoriteId: favoriteId)
        let savedAt = await manager.querySavedAt(favoriteId: favoriteId) ?? favorite.updatedAt
        let current = VersionHistoryEntry(reference: .current, date: savedAt)
        let past = versions.map { version in
            VersionHistoryEntry(
                reference: .savedQueryVersion(id: version.id),
                summary: version.name == favorite.name ? nil : version.name,
                date: version.savedAt
            )
        }
        return VersionHistoryPage(
            entries: [current] + past,
            notice: .keepsLatestVersions(SQLFavoriteStorage.retainedVersionCount)
        )
    }

    func content(of reference: VersionHistoryReference) async throws -> String {
        switch reference {
        case .current:
            guard let favorite = await manager.fetchFavorite(id: favoriteId) else {
                throw VersionHistoryError.subjectNotFound
            }
            return favorite.query
        case .savedQueryVersion(let id):
            return try await version(id: id).query
        case .gitRevision:
            throw VersionHistoryError.versionNotFound
        }
    }

    func prepareRestore(_ reference: VersionHistoryReference) async throws -> VersionRestorePlan {
        guard case .savedQueryVersion(let id) = reference else {
            throw VersionHistoryError.versionNotFound
        }
        let version = try await version(id: id)
        let manager = manager
        return VersionRestorePlan(replacesUncommittedChanges: false) {
            guard await manager.restore(version) else {
                throw VersionHistoryError.subjectNotFound
            }
        }
    }

    private func version(id: Int64) async throws -> SQLFavoriteVersion {
        let versions = await manager.fetchVersions(favoriteId: favoriteId)
        guard let version = versions.first(where: { $0.id == id }) else {
            throw VersionHistoryError.versionNotFound
        }
        return version
    }
}
