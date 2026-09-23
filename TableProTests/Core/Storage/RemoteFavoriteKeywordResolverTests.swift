//
//  RemoteFavoriteKeywordResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Remote favorite keyword resolver")
struct RemoteFavoriteKeywordResolverTests {
    private let connectionId = UUID()
    private let older = Date(timeIntervalSince1970: 1_000)
    private let newer = Date(timeIntervalSince1970: 2_000)

    private func favorite(
        id: UUID = UUID(),
        keyword: String?,
        connectionId: UUID?,
        createdAt: Date
    ) -> SQLFavorite {
        SQLFavorite(
            id: id,
            name: "Query",
            query: "SELECT 1",
            keyword: keyword,
            connectionId: connectionId,
            createdAt: createdAt
        )
    }

    @Test("Nothing is released when no two favorites share a keyword in one connection")
    func noConflictReleasesNothing() {
        let local = favorite(keyword: "rev", connectionId: connectionId, createdAt: older)
        let incoming = favorite(keyword: "cost", connectionId: connectionId, createdAt: newer)

        let resolution = RemoteFavoriteKeywordResolver.resolve(incoming: [incoming], local: [local])

        #expect(resolution.upserts == [incoming])
        #expect(resolution.releasedIds.isEmpty)
    }

    @Test("One keyword in two connections is not a conflict")
    func differentConnectionsDoNotCompete() {
        let local = favorite(keyword: "rev", connectionId: UUID(), createdAt: older)
        let incoming = favorite(keyword: "rev", connectionId: connectionId, createdAt: newer)

        let resolution = RemoteFavoriteKeywordResolver.resolve(incoming: [incoming], local: [local])

        #expect(resolution.upserts == [incoming])
        #expect(resolution.releasedIds.isEmpty)
    }

    @Test("Global favorites never compete for a keyword")
    func globalFavoritesDoNotCompete() {
        let first = favorite(keyword: "rev", connectionId: nil, createdAt: older)
        let second = favorite(keyword: "rev", connectionId: nil, createdAt: newer)

        let resolution = RemoteFavoriteKeywordResolver.resolve(incoming: [first, second], local: [])

        #expect(resolution.upserts == [first, second])
        #expect(resolution.releasedIds.isEmpty)
    }

    @Test("The older of two local and incoming holders keeps the keyword")
    func olderHolderWins() {
        let local = favorite(keyword: "rev", connectionId: connectionId, createdAt: older)
        let incoming = favorite(keyword: "rev", connectionId: connectionId, createdAt: newer)

        let resolution = RemoteFavoriteKeywordResolver.resolve(incoming: [incoming], local: [local])

        #expect(resolution.upserts.first?.keyword == nil)
        #expect(resolution.releasedIncomingIds == [incoming.id])
        #expect(resolution.releasedLocalIds.isEmpty)
        #expect(resolution.vacatedLocalIds.isEmpty)
    }

    @Test("A newer local holder gives its keyword up before the older incoming one is written")
    func newerLocalHolderIsVacated() {
        let local = favorite(keyword: "rev", connectionId: connectionId, createdAt: newer)
        let incoming = favorite(keyword: "rev", connectionId: connectionId, createdAt: older)

        let resolution = RemoteFavoriteKeywordResolver.resolve(incoming: [incoming], local: [local])

        #expect(resolution.upserts == [incoming])
        #expect(resolution.releasedLocalIds == [local.id])
        #expect(resolution.vacatedLocalIds == [local.id])
    }

    @Test("Two incoming holders created at the same moment are settled by id")
    func tieIsSettledById() throws {
        let lowId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highId = try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001"))
        let high = favorite(id: highId, keyword: "rev", connectionId: connectionId, createdAt: older)
        let low = favorite(id: lowId, keyword: "rev", connectionId: connectionId, createdAt: older)

        let resolution = RemoteFavoriteKeywordResolver.resolve(incoming: [high, low], local: [])

        let winner = resolution.upserts.first { $0.id == lowId }
        #expect(resolution.releasedIncomingIds == [highId])
        #expect(winner?.keyword == "rev")
    }

    @Test("A local favorite the batch updates is judged by its incoming version")
    func incomingVersionReplacesTheLocalOne() {
        let id = UUID()
        let local = favorite(id: id, keyword: "rev", connectionId: connectionId, createdAt: older)
        let renamed = favorite(id: id, keyword: "cost", connectionId: connectionId, createdAt: older)
        let taker = favorite(keyword: "rev", connectionId: connectionId, createdAt: newer)

        let resolution = RemoteFavoriteKeywordResolver.resolve(incoming: [taker, renamed], local: [local])

        #expect(resolution.upserts == [taker, renamed])
        #expect(resolution.vacatedLocalIds == [id])
        #expect(resolution.releasedIds.isEmpty)
    }

    @Test("A record listed twice in one pull is written once, as its last version")
    func duplicateArrivalKeepsTheLastVersion() {
        let id = UUID()
        let first = favorite(id: id, keyword: "rev", connectionId: connectionId, createdAt: older)
        let last = favorite(id: id, keyword: "cost", connectionId: connectionId, createdAt: older)

        let resolution = RemoteFavoriteKeywordResolver.resolve(incoming: [first, last], local: [])

        #expect(resolution.upserts == [last])
        #expect(resolution.releasedIds.isEmpty)
    }
}
