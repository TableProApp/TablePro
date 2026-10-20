import Foundation
import TableProConnectionLibrary

internal struct RemoteFavoriteKeywordResolution: Equatable {
    let upserts: [SQLFavorite]
    let vacatedLocalIds: [UUID]
    let releasedLocalIds: [UUID]
    let releasedIncomingIds: [UUID]

    var releasedIds: [UUID] {
        releasedLocalIds + releasedIncomingIds
    }
}

// The iOS app resolves with the same shared rule, so a contested keyword settles the same way on every device.
internal enum RemoteFavoriteKeywordResolver {
    static func resolve(incoming: [SQLFavorite], local: [SQLFavorite]) -> RemoteFavoriteKeywordResolution {
        let shared = SavedQueryKeywordResolver.resolve(incoming: incoming, local: local)
        return RemoteFavoriteKeywordResolution(
            upserts: shared.upserts,
            vacatedLocalIds: shared.vacatedLocalIds,
            releasedLocalIds: shared.releasedLocalIds,
            releasedIncomingIds: shared.releasedIncomingIds
        )
    }
}
