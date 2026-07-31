//
//  MongoDBFindLimitPolicyTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MongoDB Find Limit Policy")
struct MongoDBFindLimitPolicyTests {
    @Suite("fetchLimit")
    struct FetchLimitTests {
        @Test("A parsed limit is honoured as-is")
        func parsedLimitWins() {
            #expect(MongoDBFindLimitPolicy.fetchLimit(parsedLimit: 20, rowCap: nil) == 20)
        }

        @Test("A row cap asks for one extra document so truncation is detectable")
        func rowCapAsksForOneMore() {
            #expect(MongoDBFindLimitPolicy.fetchLimit(parsedLimit: nil, rowCap: 500) == 501)
        }

        @Test("The smaller of the parsed limit and the row cap wins")
        func smallerBoundWins() {
            #expect(MongoDBFindLimitPolicy.fetchLimit(parsedLimit: 20, rowCap: 500) == 20)
            #expect(MongoDBFindLimitPolicy.fetchLimit(parsedLimit: 5_000, rowCap: 500) == 501)
        }

        @Test("An unbounded query never asks for more than the emergency ceiling")
        func unboundedFallsBackToCeiling() {
            #expect(MongoDBFindLimitPolicy.fetchLimit(parsedLimit: nil, rowCap: nil) == PluginRowLimits.emergencyMax)
        }

        @Test("A non-positive bound is ignored rather than sent to the server")
        func ignoresNonPositiveBounds() {
            #expect(MongoDBFindLimitPolicy.fetchLimit(parsedLimit: 0, rowCap: nil) == PluginRowLimits.emergencyMax)
            #expect(MongoDBFindLimitPolicy.fetchLimit(parsedLimit: nil, rowCap: 0) == PluginRowLimits.emergencyMax)
        }

        @Test("The emergency ceiling is never exceeded")
        func neverExceedsCeiling() {
            let limit = MongoDBFindLimitPolicy.fetchLimit(
                parsedLimit: nil, rowCap: PluginRowLimits.emergencyMax
            )
            #expect(limit == PluginRowLimits.emergencyMax)
        }
    }

    @Suite("isTruncated")
    struct IsTruncatedTests {
        @Test("Exactly the cap is not truncated")
        func exactlyCapIsNotTruncated() {
            #expect(!MongoDBFindLimitPolicy.isTruncated(rowCount: 500, rowCap: 500))
        }

        @Test("One beyond the cap is truncated")
        func oneBeyondCapIsTruncated() {
            #expect(MongoDBFindLimitPolicy.isTruncated(rowCount: 501, rowCap: 500))
        }

        @Test("No cap means never truncated")
        func noCapIsNeverTruncated() {
            #expect(!MongoDBFindLimitPolicy.isTruncated(rowCount: 1_000_000, rowCap: nil))
        }
    }
}
