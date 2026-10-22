import Foundation

public struct SavedQueryKeywordResolution<Query: SavedQueryRepresentable> {
    public let upserts: [Query]
    // Local rows whose keyword is cleared before the upserts land: each is replaced or loses its keyword.
    public let vacatedLocalIds: [UUID]
    public let releasedLocalIds: [UUID]
    public let releasedIncomingIds: [UUID]

    public var releasedIds: [UUID] {
        releasedLocalIds + releasedIncomingIds
    }
}

extension SavedQueryKeywordResolution: Equatable where Query: Equatable {}

extension SavedQueryKeywordResolution: Sendable where Query: Sendable {}

// Every device runs this one rule on the same records, so they all release the same losers and converge.
public enum SavedQueryKeywordResolver {
    public static func resolve<Query: SavedQueryRepresentable>(
        incoming: [Query],
        local: [Query]
    ) -> SavedQueryKeywordResolution<Query> {
        let upserts = latestVersions(of: incoming)
        let incomingIds = Set(upserts.map(\.id))
        let bystanders = local.filter { !incomingIds.contains($0.id) }
        let losingIds = keywordLosers(among: bystanders + upserts)

        return SavedQueryKeywordResolution(
            upserts: upserts.map { losingIds.contains($0.id) ? releasingKeyword($0) : $0 },
            vacatedLocalIds: local.map(\.id).filter { incomingIds.contains($0) || losingIds.contains($0) },
            releasedLocalIds: bystanders.map(\.id).filter { losingIds.contains($0) },
            releasedIncomingIds: upserts.map(\.id).filter { losingIds.contains($0) }
        )
    }

    public static func holdsKeywordFirst<Query: SavedQueryRepresentable>(_ lhs: Query, _ rhs: Query) -> Bool {
        guard lhs.createdAt == rhs.createdAt else { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private struct KeywordSlot: Hashable {
        let keyword: String
        let connectionId: UUID
    }

    // A global keyword is never contested: the local save check already keeps it unique everywhere.
    private static func slot<Query: SavedQueryRepresentable>(of query: Query) -> KeywordSlot? {
        guard let keyword = query.keyword, let connectionId = query.connectionId else { return nil }
        return KeywordSlot(keyword: keyword, connectionId: connectionId)
    }

    private static func keywordLosers<Query: SavedQueryRepresentable>(among contenders: [Query]) -> Set<UUID> {
        var claimants: [KeywordSlot: [Query]] = [:]
        for query in contenders {
            guard let slot = slot(of: query) else { continue }
            claimants[slot, default: []].append(query)
        }
        return Set(claimants.values.flatMap { $0.sorted(by: holdsKeywordFirst).dropFirst().map(\.id) })
    }

    private static func latestVersions<Query: SavedQueryRepresentable>(of queries: [Query]) -> [Query] {
        var latestById: [UUID: Query] = [:]
        var arrivalOrder: [UUID] = []
        for query in queries where latestById.updateValue(query, forKey: query.id) == nil {
            arrivalOrder.append(query.id)
        }
        return arrivalOrder.compactMap { latestById[$0] }
    }

    private static func releasingKeyword<Query: SavedQueryRepresentable>(_ query: Query) -> Query {
        var released = query
        released.keyword = nil
        return released
    }
}
