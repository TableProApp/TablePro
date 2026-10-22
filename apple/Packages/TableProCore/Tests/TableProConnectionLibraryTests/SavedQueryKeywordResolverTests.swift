import Foundation
@testable import TableProConnectionLibrary
import Testing

private struct ResolverQuery: SavedQueryRepresentable, Equatable {
    var id = UUID()
    var name = "Query"
    var query = "SELECT 1"
    var keyword: String?
    var folderId: UUID?
    var connectionId: UUID?
    var sortOrder = 0
    var createdAt: Date
}

struct SavedQueryKeywordResolverTests {
    private let connectionId = UUID()
    private let older = Date(timeIntervalSince1970: 1_000)
    private let newer = Date(timeIntervalSince1970: 2_000)

    private func query(
        id: UUID = UUID(),
        keyword: String?,
        connectionId: UUID?,
        createdAt: Date
    ) -> ResolverQuery {
        ResolverQuery(id: id, keyword: keyword, connectionId: connectionId, createdAt: createdAt)
    }

    @Test("Nothing is released when no two queries share a keyword in one connection")
    func noConflictReleasesNothing() {
        let local = query(keyword: "rev", connectionId: connectionId, createdAt: older)
        let incoming = query(keyword: "cost", connectionId: connectionId, createdAt: newer)

        let resolution = SavedQueryKeywordResolver.resolve(incoming: [incoming], local: [local])

        #expect(resolution.upserts == [incoming])
        #expect(resolution.releasedIds.isEmpty)
        #expect(resolution.vacatedLocalIds.isEmpty)
    }

    @Test("One keyword in two connections is not a conflict")
    func differentConnectionsDoNotCompete() {
        let local = query(keyword: "rev", connectionId: UUID(), createdAt: older)
        let incoming = query(keyword: "rev", connectionId: connectionId, createdAt: newer)

        let resolution = SavedQueryKeywordResolver.resolve(incoming: [incoming], local: [local])

        #expect(resolution.upserts == [incoming])
        #expect(resolution.releasedIds.isEmpty)
    }

    @Test("Global queries never compete for a keyword")
    func globalQueriesDoNotCompete() {
        let first = query(keyword: "rev", connectionId: nil, createdAt: older)
        let second = query(keyword: "rev", connectionId: nil, createdAt: newer)
        let scoped = query(keyword: "rev", connectionId: connectionId, createdAt: newer)

        let resolution = SavedQueryKeywordResolver.resolve(incoming: [first, second, scoped], local: [])

        #expect(resolution.upserts == [first, second, scoped])
        #expect(resolution.releasedIds.isEmpty)
    }

    @Test("The older of a local and an incoming holder keeps the keyword")
    func olderLocalHolderWins() {
        let local = query(keyword: "rev", connectionId: connectionId, createdAt: older)
        let incoming = query(keyword: "rev", connectionId: connectionId, createdAt: newer)

        let resolution = SavedQueryKeywordResolver.resolve(incoming: [incoming], local: [local])

        #expect(resolution.upserts.first?.keyword == nil)
        #expect(resolution.upserts.first?.name == incoming.name)
        #expect(resolution.releasedIncomingIds == [incoming.id])
        #expect(resolution.releasedLocalIds.isEmpty)
        #expect(resolution.vacatedLocalIds.isEmpty)
    }

    @Test("A newer local holder gives its keyword up to an older incoming one")
    func newerLocalHolderIsVacated() {
        let local = query(keyword: "rev", connectionId: connectionId, createdAt: newer)
        let incoming = query(keyword: "rev", connectionId: connectionId, createdAt: older)

        let resolution = SavedQueryKeywordResolver.resolve(incoming: [incoming], local: [local])

        #expect(resolution.upserts == [incoming])
        #expect(resolution.releasedLocalIds == [local.id])
        #expect(resolution.vacatedLocalIds == [local.id])
        #expect(resolution.releasedIds == [local.id])
    }

    @Test("Two holders created at the same moment are settled by id")
    func tieIsSettledById() throws {
        let lowId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highId = try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001"))
        let high = query(id: highId, keyword: "rev", connectionId: connectionId, createdAt: older)
        let low = query(id: lowId, keyword: "rev", connectionId: connectionId, createdAt: older)

        let resolution = SavedQueryKeywordResolver.resolve(incoming: [high, low], local: [])

        #expect(resolution.releasedIncomingIds == [highId])
        #expect(resolution.upserts.first { $0.id == lowId }?.keyword == "rev")
        #expect(SavedQueryKeywordResolver.holdsKeywordFirst(low, high))
        #expect(!SavedQueryKeywordResolver.holdsKeywordFirst(high, low))
    }

    @Test("A local query the batch updates is judged by its incoming version")
    func incomingVersionReplacesTheLocalOne() {
        let id = UUID()
        let local = query(id: id, keyword: "rev", connectionId: connectionId, createdAt: older)
        let renamed = query(id: id, keyword: "cost", connectionId: connectionId, createdAt: older)
        let taker = query(keyword: "rev", connectionId: connectionId, createdAt: newer)

        let resolution = SavedQueryKeywordResolver.resolve(incoming: [taker, renamed], local: [local])

        #expect(resolution.upserts == [taker, renamed])
        #expect(resolution.vacatedLocalIds == [id])
        #expect(resolution.releasedIds.isEmpty)
    }

    @Test("A record listed twice in one pull is written once, as its last version")
    func duplicateArrivalKeepsTheLastVersion() {
        let id = UUID()
        let first = query(id: id, keyword: "rev", connectionId: connectionId, createdAt: older)
        let last = query(id: id, keyword: "cost", connectionId: connectionId, createdAt: older)

        let resolution = SavedQueryKeywordResolver.resolve(incoming: [first, last], local: [])

        #expect(resolution.upserts == [last])
        #expect(resolution.releasedIds.isEmpty)
    }

    @Test("Two devices resolving the same records release the same loser")
    func resolutionConverges() {
        let oldest = query(keyword: "rev", connectionId: connectionId, createdAt: older)
        let newest = query(keyword: "rev", connectionId: connectionId, createdAt: newer)

        let here = SavedQueryKeywordResolver.resolve(incoming: [newest], local: [oldest])
        let there = SavedQueryKeywordResolver.resolve(incoming: [oldest], local: [newest])

        #expect(here.releasedIds == [newest.id])
        #expect(there.releasedIds == [newest.id])
    }
}
