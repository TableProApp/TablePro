import Foundation
@testable import TableProConnectionLibrary
import Testing

@Suite("Recent connections ledger")
struct RecentConnectionsLedgerTests {
    @Test("Recording moves a connection to the front without duplicating it")
    func recordDeduplicates() {
        let a = UUID(), b = UUID()
        var ledger = RecentConnectionsLedger()
        ledger.record(a, at: Date(timeIntervalSince1970: 1))
        ledger.record(b, at: Date(timeIntervalSince1970: 2))
        ledger.record(a, at: Date(timeIntervalSince1970: 3))
        #expect(ledger.entries.map(\.id) == [a, b])
        #expect(ledger.lastConnected[a] == Date(timeIntervalSince1970: 3))
    }

    @Test("The ledger keeps at most its capacity")
    func capacity() {
        var ledger = RecentConnectionsLedger()
        for index in 0..<(RecentConnectionsLedger.capacity + 10) {
            ledger.record(UUID(), at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(ledger.entries.count == RecentConnectionsLedger.capacity)
    }

    @Test("Retaining drops deleted connections")
    func retain() {
        let kept = UUID(), deleted = UUID()
        var ledger = RecentConnectionsLedger()
        ledger.record(kept, at: Date(timeIntervalSince1970: 1))
        ledger.record(deleted, at: Date(timeIntervalSince1970: 2))
        ledger.retain(only: [kept])
        #expect(ledger.entries.map(\.id) == [kept])
    }

    @Test("Decoding normalizes duplicates and order")
    func decodeNormalizes() throws {
        let a = UUID()
        let entries = [
            RecentConnectionsLedger.Entry(id: a, connectedAt: Date(timeIntervalSince1970: 1)),
            RecentConnectionsLedger.Entry(id: a, connectedAt: Date(timeIntervalSince1970: 5))
        ]
        let data = try JSONEncoder().encode(["entries": entries])
        let ledger = try JSONDecoder().decode(RecentConnectionsLedger.self, from: data)
        #expect(ledger.entries == [RecentConnectionsLedger.Entry(id: a, connectedAt: Date(timeIntervalSince1970: 5))])
    }
}
