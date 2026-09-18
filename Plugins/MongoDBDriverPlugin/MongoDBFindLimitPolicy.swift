//
//  MongoDBFindLimitPolicy.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

enum MongoDBFindLimitPolicy {
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

    static func isTruncated(rowCount: Int, rowCap: Int?) -> Bool {
        guard let rowCap, rowCap > 0 else { return false }
        return rowCount > rowCap
    }
}
