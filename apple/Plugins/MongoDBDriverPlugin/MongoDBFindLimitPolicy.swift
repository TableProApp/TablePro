//
//  MongoDBFindLimitPolicy.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

nonisolated enum MongoDBFindLimitPolicy {
    /// Server-side limit for a user query. One document beyond the row cap is requested so the
    /// caller can tell "exactly a full page" from "there is more", without ever asking the server
    /// for the whole collection.
    static func fetchLimit(parsedLimit: Int?, rowCap: Int?) -> Int {
        var candidates: [Int] = []
        if let parsedLimit, parsedLimit > 0 {
            candidates.append(parsedLimit)
        }
        if let rowCap, rowCap > 0 {
            candidates.append(rowCap + 1)
        }
        return min(candidates.min() ?? PluginRowLimits.emergencyMax, PluginRowLimits.emergencyMax)
    }

    // One past the limit, so the server closes the cursor with the first batch and no getMore follows.
    // The emergency ceiling means no row cap: an export keeps the default batch, so its first rows arrive early.
    static func firstBatchSize(limit: Int) -> Int? {
        guard limit > 0, limit < PluginRowLimits.emergencyMax else { return nil }
        return limit + 1
    }

    static func isTruncated(rowCount: Int, rowCap: Int?) -> Bool {
        guard let rowCap, rowCap > 0 else { return false }
        return rowCount > rowCap
    }
}
