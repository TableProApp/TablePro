import Foundation
@testable import TablePro
import Testing

struct TableHealthLedgerTests {
    private typealias Fixture = TableHealthFixture

    private let logs = Fixture.finding(table: "logs")
    private let events = Fixture.finding(table: "events")
    private let noteIndex = Fixture.finding(.unusedIndex, table: "orders", object: "orders_note_idx")

    private static func day(_ number: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(number) * 86_400)
    }

    private func recorded(
        _ runs: [[(kind: TableHealthCheckKind, outcome: TableHealthCheckResult.Outcome, findings: [TableHealthFinding])]],
        into ledger: TableHealthLedger = TableHealthLedger()
    ) -> TableHealthLedger {
        // Run n is recorded on day n, so a date in an expectation names its run.
        var ledger = ledger
        for run in runs {
            ledger = ledger.recording(Fixture.report(run), at: Self.day(ledger.runIndex + 1))
        }
        return ledger
    }

    private func missingKeys(_ findings: [TableHealthFinding]) -> [(
        kind: TableHealthCheckKind, outcome: TableHealthCheckResult.Outcome, findings: [TableHealthFinding]
    )] {
        [(.missingPrimaryKey, .completed, findings)]
    }

    @Test("The first run marks nothing new: there is nothing to compare it with")
    func firstRunMarksNothingNew() {
        let ledger = recorded([missingKeys([logs])])
        #expect(ledger.runIndex == 1)
        #expect(ledger.status(of: logs.id) == .none)
        #expect(ledger.firstSeen(logs.id) == Self.day(1))
    }

    @Test("A finding first seen in the latest run is new, and only for that run")
    func laterFindingIsNew() {
        let second = recorded([missingKeys([logs]), missingKeys([logs, events])])
        #expect(second.status(of: events.id) == .new)
        #expect(second.status(of: logs.id) == .none)

        let third = recorded([missingKeys([logs, events])], into: second)
        #expect(third.status(of: events.id) == .none)
        #expect(third.firstSeen(events.id) == Self.day(2))
        #expect(third.lastSeen(events.id) == Self.day(3))
    }

    @Test("A check's first completion marks nothing new, even after earlier runs of other checks")
    func firstCompletionOfACheckMarksNothingNew() {
        let ledger = recorded([
            [(.missingPrimaryKey, .completed, [logs]), (.unusedIndex, .skipped("track_counts is off"), [])],
            [(.missingPrimaryKey, .completed, [logs]), (.unusedIndex, .completed, [noteIndex])]
        ])
        #expect(ledger.status(of: noteIndex.id) == .none)
    }

    @Test("A failed or skipped check resolves nothing and moves nothing")
    func failedAndSkippedChecksResolveNothing() {
        let ledger = recorded([
            missingKeys([logs]),
            [(.missingPrimaryKey, .failed("permission denied"), [])],
            [(.missingPrimaryKey, .skipped("standby"), [])]
        ])
        #expect(ledger.resolved.isEmpty)
        #expect(ledger.lastSeen(logs.id) == Self.day(1))
        #expect(ledger.status(of: logs.id) == .none)
    }

    @Test("A finding absent from a completed run is resolved once, at that run")
    func absentFindingResolvesOnce() throws {
        let ledger = recorded([missingKeys([logs, events]), missingKeys([logs]), missingKeys([logs])])
        let resolved = try #require(ledger.resolved.first)
        #expect(ledger.resolved.count == 1)
        #expect(resolved.id == events.id)
        #expect(resolved.resolvedRun == 2)
        #expect(resolved.resolvedAt == Self.day(2))
        #expect(resolved.lastSeen == Self.day(1))
    }

    @Test("A resolved finding that comes back is open again and new from that run")
    func reappearingFindingIsNewAgain() {
        let ledger = recorded([missingKeys([logs, events]), missingKeys([logs]), missingKeys([logs, events])])
        #expect(ledger.resolved.isEmpty)
        #expect(ledger.status(of: events.id) == .new)
        #expect(ledger.firstSeen(events.id) == Self.day(3))
    }

    @Test("An ignore wins over new and survives the finding going away and coming back")
    func ignoreSurvives() {
        var ledger = recorded([missingKeys([logs]), missingKeys([logs, events])])
        ledger = ledger.ignoring([events.id], at: Self.day(10))
        #expect(ledger.status(of: events.id) == .ignored)
        #expect(ledger.ignored[events.id] == Self.day(10))

        ledger = recorded([missingKeys([logs]), missingKeys([logs, events])], into: ledger)
        #expect(ledger.status(of: events.id) == .ignored)

        ledger = ledger.ignoring([events.id], at: Self.day(20))
        #expect(ledger.ignored[events.id] == Self.day(10))

        ledger = ledger.unignoring([events.id])
        #expect(ledger.status(of: events.id) == .new)
        #expect(!ledger.isIgnored(events.id))
    }

    @Test("Resolved findings list the latest run first, by run before date, so a clock change cannot reorder them")
    func resolvedOrderFollowsRuns() {
        var ledger = TableHealthLedger()
        ledger = ledger.recording(Fixture.report(missingKeys([logs, events])), at: Self.day(5))
        ledger = ledger.recording(Fixture.report(missingKeys([events])), at: Self.day(6))
        ledger = ledger.recording(Fixture.report(missingKeys([])), at: Self.day(1))
        #expect(ledger.resolved.map { $0.id } == [events.id, logs.id])
    }

    @Test("Only the 1,000 most recently resolved findings are kept")
    func resolvedIsCapped() {
        let old = Fixture.finding(table: "old")
        let many = (0..<TableHealthLedger.resolvedLimit).map { Fixture.finding(table: "t\($0)") }
        let ledger = recorded([missingKeys([old]), missingKeys([]), missingKeys(many), missingKeys([])])
        #expect(ledger.resolved.count == TableHealthLedger.resolvedLimit)
        #expect(!ledger.resolved.contains { $0.id == old.id })
        #expect(ledger.entries[old.id] == nil)
    }

    @Test("Clearing resolved keeps open findings and ignores")
    func clearingResolvedKeepsTheRest() {
        let ledger = recorded([missingKeys([logs, events]), missingKeys([logs])])
            .ignoring([events.id], at: Self.day(9))
            .clearingResolved()
        #expect(ledger.resolved.isEmpty)
        #expect(ledger.entries[logs.id] != nil)
        #expect(ledger.entries[events.id] == nil)
        #expect(ledger.isIgnored(events.id))
    }

    @Test("Without recording, a finding is new when recording it would mark it new")
    func mcpStatusWithoutRecording() {
        let ledger = recorded([missingKeys([logs, events]), missingKeys([logs])]).ignoring([noteIndex.id], at: Self.day(9))
        let fresh = Fixture.finding(table: "fresh")
        let unrunCheck = Fixture.finding(.bloat, table: "orders")

        #expect(ledger.mcpStatus(of: fresh.id) == .new)
        #expect(ledger.mcpStatus(of: events.id) == .new)
        #expect(ledger.mcpStatus(of: logs.id) == .none)
        #expect(ledger.mcpStatus(of: unrunCheck.id) == .none)
        #expect(ledger.mcpStatus(of: noteIndex.id) == .ignored)
        #expect(TableHealthLedger().mcpStatus(of: fresh.id) == .none)
    }

    @Test("Renaming a table moves its findings and ignores, and leaves other schemas alone")
    func renamingTable() {
        let other = Fixture.finding(schema: "audit", table: "logs")
        let ledger = recorded([missingKeys([logs, other])])
            .ignoring([logs.id], at: Self.day(9))
            .renamingTable(schema: "public", from: "logs", to: "journal")
        let journal = Fixture.finding(table: "journal")

        #expect(ledger.entries[journal.id] != nil)
        #expect(ledger.entries[logs.id] == nil)
        #expect(ledger.isIgnored(journal.id))
        #expect(ledger.entries[other.id] != nil)
    }

    @Test("Renaming a schema moves every finding in it")
    func renamingSchema() {
        let ledger = recorded([missingKeys([logs, events])]).renamingSchema(from: "public", to: "app")
        #expect(ledger.entries[Fixture.finding(schema: "app", table: "logs").id] != nil)
        #expect(ledger.entries[Fixture.finding(schema: "app", table: "events").id] != nil)
        #expect(ledger.entries.count == 2)
    }

    @Test("Dropping a table forgets its findings and ignores, and nothing else")
    func droppingTable() {
        let ledger = recorded([missingKeys([logs, events])])
            .ignoring([logs.id], at: Self.day(9))
            .droppingTable(schema: "public", name: "logs")
        #expect(ledger.entries[logs.id] == nil)
        #expect(!ledger.isIgnored(logs.id))
        #expect(ledger.entries[events.id] != nil)
    }

    @Test("Dropping a schema forgets every finding in it")
    func droppingSchema() {
        let other = Fixture.finding(schema: "audit", table: "logs")
        let ledger = recorded([missingKeys([logs, events, other])]).droppingSchema("public")
        #expect(ledger.entries.count == 1)
        #expect(ledger.entries[other.id] != nil)
    }

    @Test("A ledger survives encoding and decoding")
    func codableRoundTrip() throws {
        let ledger = recorded([missingKeys([logs, events]), missingKeys([logs])]).ignoring([noteIndex.id], at: Self.day(9))
        let decoded = try JSONDecoder().decode(TableHealthLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
        #expect(decoded.status(of: noteIndex.id) == .ignored)
        #expect(decoded.resolved.map { $0.id } == [events.id])
    }

    @Test("Entries and ignores of a kind this build does not know survive a round trip as written")
    func unknownKindSurvives() throws {
        let json = """
            {
              "runIndex": 4,
              "firstCompletedRun": {"futureCheck": 1, "missingPrimaryKey": 1},
              "lastCompletedRun": {"futureCheck": 4, "missingPrimaryKey": 4},
              "entries": {
                "futureCheck.public.orders.-": {"firstSeenRun": 2, "firstSeen": 0, "lastSeen": 0, "severity": [1, "high", null]},
                "missingPrimaryKey.public.logs.-": {"firstSeenRun": 1, "firstSeen": 0, "lastSeen": 0}
              },
              "ignored": {"futureCheck.public.orders.-": 0}
            }
            """
        let ledger = try JSONDecoder().decode(TableHealthLedger.self, from: Data(json.utf8))
        #expect(ledger.entries.count == 1)
        #expect(ledger.entries[logs.id] != nil)
        #expect(ledger.ignored.isEmpty)

        let renamed = ledger.renamingTable(schema: "public", from: "logs", to: "journal")
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(renamed)) as? [String: Any]
        let entries = try #require(written?["entries"] as? [String: Any])
        let future = try #require(entries["futureCheck.public.orders.-"] as? NSDictionary)
        #expect(future == ([
            "firstSeenRun": 2, "firstSeen": 0, "lastSeen": 0, "severity": [1, "high", NSNull()] as [Any]
        ] as NSDictionary))
        #expect(entries["missingPrimaryKey.public.journal.-"] != nil)
        let ignored = try #require(written?["ignored"] as? [String: Any])
        #expect(ignored["futureCheck.public.orders.-"] != nil)
        let lastCompleted = try #require(written?["lastCompletedRun"] as? [String: Int])
        #expect(lastCompleted["futureCheck"] == 4)
    }

    @Test("A finding id's storage key round-trips any name and keeps an absent part apart from an empty one")
    func storageKeyRoundTrips() {
        let ids = [
            TableHealthFindingID(kind: .unusedIndex, schema: "public", table: "orders", object: "orders_note_idx"),
            TableHealthFindingID(kind: .nearLimit, schema: "public", table: nil, object: "seq"),
            TableHealthFindingID(kind: .missingPrimaryKey, schema: nil, table: "odd.name-%2E", object: nil),
            TableHealthFindingID(kind: .missingPrimaryKey, schema: "", table: "-", object: "表\n\u{2028}"),
            TableHealthFindingID(kind: .bloat, schema: "a b", table: "e\u{301}", object: nil)
        ]
        for id in ids {
            #expect(TableHealthFindingID(storageKey: id.storageKey) == id, "\(id.storageKey)")
        }
        #expect(Set(ids.map { $0.storageKey }).count == ids.count)
        #expect(ids[0].storageKey == "unusedIndex.public.orders.orders_note_idx")
        #expect(TableHealthFindingID(storageKey: "futureCheck.public.orders.-") == nil)
        #expect(TableHealthFindingID(storageKey: "bloat.public") == nil)
    }
}
