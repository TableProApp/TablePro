//
//  RemoteFavoriteKeywordResolver.swift
//  TablePro
//

import Foundation

internal struct RemoteFavoriteKeywordResolution: Equatable {
    let upserts: [SQLFavorite]
    let vacatedLocalIds: [UUID]
    let releasedLocalIds: [UUID]
    let releasedIncomingIds: [UUID]

    var releasedIds: [UUID] {
        releasedLocalIds + releasedIncomingIds
    }
}

internal enum RemoteFavoriteKeywordResolver {
    static func resolve(incoming: [SQLFavorite], local: [SQLFavorite]) -> RemoteFavoriteKeywordResolution {
        let upserts = latestVersions(of: incoming)
        let incomingIds = Set(upserts.map(\.id))
        let bystanders = local.filter { !incomingIds.contains($0.id) }
        let losingIds = keywordLosers(among: bystanders + upserts)

        return RemoteFavoriteKeywordResolution(
            upserts: upserts.map { losingIds.contains($0.id) ? releasingKeyword($0) : $0 },
            vacatedLocalIds: local.map(\.id).filter { incomingIds.contains($0) || losingIds.contains($0) },
            releasedLocalIds: bystanders.map(\.id).filter { losingIds.contains($0) },
            releasedIncomingIds: upserts.map(\.id).filter { losingIds.contains($0) }
        )
    }

    static func holdsKeywordFirst(_ lhs: SQLFavorite, _ rhs: SQLFavorite) -> Bool {
        guard lhs.createdAt == rhs.createdAt else { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private struct KeywordSlot: Hashable {
        let keyword: String
        let connectionId: UUID
    }

    private static func slot(of favorite: SQLFavorite) -> KeywordSlot? {
        guard let keyword = favorite.keyword, let connectionId = favorite.connectionId else { return nil }
        return KeywordSlot(keyword: keyword, connectionId: connectionId)
    }

    private static func keywordLosers(among contenders: [SQLFavorite]) -> Set<UUID> {
        var claimants: [KeywordSlot: [SQLFavorite]] = [:]
        for favorite in contenders {
            guard let slot = slot(of: favorite) else { continue }
            claimants[slot, default: []].append(favorite)
        }
        return Set(claimants.values.flatMap { $0.sorted(by: holdsKeywordFirst).dropFirst().map(\.id) })
    }

    private static func latestVersions(of favorites: [SQLFavorite]) -> [SQLFavorite] {
        var latestById: [UUID: SQLFavorite] = [:]
        var arrivalOrder: [UUID] = []
        for favorite in favorites where latestById.updateValue(favorite, forKey: favorite.id) == nil {
            arrivalOrder.append(favorite.id)
        }
        return arrivalOrder.compactMap { latestById[$0] }
    }

    private static func releasingKeyword(_ favorite: SQLFavorite) -> SQLFavorite {
        var released = favorite
        released.keyword = nil
        return released
    }
}
