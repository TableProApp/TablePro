//
//  CassandraCellLifetimeTests.swift
//  TableProCassandraCoreTests
//

import TableProCassandraCore
import Testing

struct CassandraCellLifetimeTests {
    @Test("A cell read with its TTL() is expiring, without one permanent, and as null unknown")
    func readLifetimes() {
        #expect(CassandraCellLifetime(valueIsNull: false, timeToLive: "86400") == .expiring(seconds: 86_400))
        #expect(CassandraCellLifetime(valueIsNull: false, timeToLive: nil) == .permanent)
        #expect(CassandraCellLifetime(valueIsNull: true, timeToLive: nil) == nil)
        #expect(CassandraCellLifetime(valueIsNull: true, timeToLive: "30") == nil)
        #expect(CassandraCellLifetime(valueIsNull: false, timeToLive: "soon") == nil)
    }

    @Test("What is left is the TTL less the whole seconds since the read, and at least one", arguments: [
        (100, Duration.seconds(10), 90),
        (100, Duration.milliseconds(10_900), 90),
        (100, Duration.zero, 100),
        (5, Duration.seconds(30), 1),
        (5, Duration.seconds(5), 1),
        (100, Duration.seconds(-3), 100),
    ])
    func remaining(seconds: Int, elapsed: Duration, expected: Int) {
        #expect(CassandraCellLifetime.remaining(seconds: seconds, after: elapsed) == expected)
    }

    @Test("An edit keeps what an expiring cell had left, and a permanent one only when the table has a default TTL")
    func rowTimesToLive() throws {
        let readAt = ContinuousClock.now
        let later = readAt.advanced(by: .seconds(30))
        let lifetimes: [CassandraCellLifetime?] = [.expiring(seconds: 100), .permanent, nil]
        let columns = ["note", "address", "owner"]

        func row(defaultTimeToLive: Int?) throws -> CassandraRowLifetimes {
            let layout = try #require(CassandraTableLayoutTests.visits(defaultTimeToLive: defaultTimeToLive))
            return try #require(CassandraRowLifetimes(
                columns: columns, lifetimes: lifetimes, readAt: readAt, layout: layout
            ))
        }

        let noDefault = try row(defaultTimeToLive: 0)
        #expect(noDefault.timeToLive(of: "note", at: later) == 70)
        #expect(noDefault.timeToLive(of: "address", at: later) == nil)
        #expect(noDefault.timeToLive(of: "owner", at: later) == nil)
        #expect(noDefault.timeToLive(of: "Count", at: later) == nil)
        #expect(try row(defaultTimeToLive: 3_600).timeToLive(of: "address", at: later) == 0)
        #expect(try row(defaultTimeToLive: nil).timeToLive(of: "address", at: later) == 0)
    }

    @Test("A cell whose TTL ran out since the read has expired, and no other cell has")
    func expiredCells() throws {
        let readAt = ContinuousClock.now
        let layout = try #require(CassandraTableLayoutTests.visits(defaultTimeToLive: 0))
        let row = try #require(CassandraRowLifetimes(
            columns: ["note", "address"], lifetimes: [.expiring(seconds: 100), .permanent], readAt: readAt, layout: layout
        ))
        #expect(!row.hasExpired("note", at: readAt.advanced(by: .seconds(99))))
        #expect(row.hasExpired("note", at: readAt.advanced(by: .seconds(100))))
        #expect(!row.hasExpired("address", at: readAt.advanced(by: .seconds(1_000))))
        #expect(!row.hasExpired("owner", at: readAt.advanced(by: .seconds(1_000))))
    }

    @Test("Nothing is kept for a row every cell of which a plain write keeps the same")
    func rowsWithNothingToKeep() throws {
        let noDefault = try #require(CassandraTableLayoutTests.visits(defaultTimeToLive: 0))
        #expect(CassandraRowLifetimes(
            columns: ["note", "owner"], lifetimes: [.permanent, nil], readAt: .now, layout: noDefault
        ) == nil)
        #expect(CassandraRowLifetimes(
            columns: ["note"], lifetimes: [.permanent, .permanent], readAt: .now, layout: noDefault
        ) == nil)
        let withDefault = try #require(CassandraTableLayoutTests.visits(defaultTimeToLive: 60))
        #expect(CassandraRowLifetimes(
            columns: ["note", "owner"], lifetimes: [.permanent, nil], readAt: .now, layout: withDefault
        ) != nil)
    }
}
