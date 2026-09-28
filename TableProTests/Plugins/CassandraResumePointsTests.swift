//
//  CassandraResumePointsTests.swift
//  TableProTests
//

import Foundation
import Testing

struct CassandraResumePointsTests {
    private let key = CassandraResumePoints.key(keyspace: "a", cql: "SELECT * FROM t", values: [], pageSize: 1_000)

    @Test("A page resumes from the farthest point at or before its offset")
    func nearestPointAtOrBefore() {
        var points = CassandraResumePoints()
        points.record(Data([1]), at: 1_000, for: key)
        points.record(Data([2]), at: 2_000, for: key)

        #expect(points.nearest(atOrBefore: 999, for: key) == nil)
        #expect(points.nearest(atOrBefore: 1_500, for: key)?.position == 1_000)
        #expect(points.nearest(atOrBefore: 2_000, for: key)?.token == Data([2]))
    }

    @Test("A point is only found under the exact keyspace, statement, values and page size it came from")
    func pointsAreKeyedByStatement() {
        var points = CassandraResumePoints()
        points.record(Data([1]), at: 1_000, for: key)

        let otherValues = CassandraResumePoints.key(keyspace: "a", cql: "SELECT * FROM t", values: ["x"], pageSize: 1_000)
        let otherPageSize = CassandraResumePoints.key(keyspace: "a", cql: "SELECT * FROM t", values: [], pageSize: 500)
        let otherKeyspace = CassandraResumePoints.key(keyspace: "b", cql: "SELECT * FROM t", values: [], pageSize: 1_000)

        #expect(points.nearest(atOrBefore: 5_000, for: otherValues) == nil)
        #expect(points.nearest(atOrBefore: 5_000, for: otherPageSize) == nil)
        #expect(points.nearest(atOrBefore: 5_000, for: otherKeyspace) == nil)
    }

    @Test("A walk that records a point drops the points past it, which came from an earlier walk")
    func recordingDropsLaterPoints() {
        var points = CassandraResumePoints()
        for position in [1_000, 2_000, 3_000, 4_000] {
            points.record(Data([UInt8(position / 1_000)]), at: position, for: key)
        }

        points.record(Data([9]), at: 1_000, for: key)

        #expect(points.nearest(atOrBefore: 4_000, for: key)?.position == 1_000)
        #expect(points.nearest(atOrBefore: 4_000, for: key)?.token == Data([9]))
    }

    @Test("Removing one statement's points leaves the others")
    func removeOneKey() {
        var points = CassandraResumePoints()
        let other = CassandraResumePoints.key(keyspace: "a", cql: "SELECT * FROM u", values: [], pageSize: 1_000)
        points.record(Data([1]), at: 1_000, for: key)
        points.record(Data([2]), at: 1_000, for: other)

        points.remove(key)

        #expect(points.nearest(atOrBefore: 1_000, for: key) == nil)
        #expect(points.nearest(atOrBefore: 1_000, for: other) != nil)
    }

    @Test("An empty paging state is never recorded")
    func emptyTokenIsIgnored() {
        var points = CassandraResumePoints()
        points.record(Data(), at: 1_000, for: key)

        #expect(points.nearest(atOrBefore: 1_000, for: key) == nil)
    }

    @Test("Only the most recent statements keep their points")
    func oldestStatementIsEvicted() {
        var points = CassandraResumePoints()
        for index in 0...CassandraResumePoints.maximumStatements {
            points.record(Data([1]), at: 100, for: "statement-\(index)")
        }

        #expect(points.nearest(atOrBefore: 100, for: "statement-0") == nil)
        #expect(points.nearest(atOrBefore: 100, for: "statement-\(CassandraResumePoints.maximumStatements)") != nil)
    }

    @Test("Clearing forgets every point")
    func removeAll() {
        var points = CassandraResumePoints()
        points.record(Data([1]), at: 1_000, for: key)
        points.removeAll()

        #expect(points.nearest(atOrBefore: 1_000, for: key) == nil)
    }

    @Test("The page size follows the browse limit within the driver's bounds")
    func pageSize() {
        #expect(CassandraResumePoints.pageSize(forLimit: 5) == 100)
        #expect(CassandraResumePoints.pageSize(forLimit: 1_000) == 1_000)
        #expect(CassandraResumePoints.pageSize(forLimit: 50_000) == 5_000)
    }
}
