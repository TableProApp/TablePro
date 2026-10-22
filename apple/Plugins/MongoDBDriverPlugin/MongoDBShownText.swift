//
//  MongoDBShownText.swift
//  MongoDBDriverPlugin
//

import Foundation

// A `$regex` matches strings only, so a pattern also matches a number, a date or an ObjectId by the text the grid shows
// for it, the way a SQL filter casts the column. Measured on 8.0: `$convert` throws past its onError on binary data and
// on a date outside years 0 to 9999, alone or inside an array or a document, and one such value fails the whole find. So
// only scalars that always convert are converted, and every other value reads as empty, left to the `$regex` arm.
nonisolated enum MongoDBShownText {
    static let convertedTypes = ["double", "int", "long", "decimal", "bool", "objectId"]
    static let earliestDateMilliseconds: Int64 = -62_167_219_200_000
    static let latestDateMilliseconds: Int64 = 253_402_300_799_999

    // An aggregation field path refuses an empty segment and one that starts with `$`, and the error fails the whole
    // find, where a `$regex` on the same name only matches nothing.
    static func reads(field: String) -> Bool {
        field.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix("$") }
    }

    static func regexMatch(field: String, pattern: String, ignoresCase: Bool) -> String {
        let regex = MongoDBQueryBuilder.escapeJsonString(pattern)
        let options = ignoresCase ? ", \"options\": \"i\"" : ""
        return "{\"$expr\": {\"$regexMatch\": {\"input\": \(expression(field: field)), \"regex\": \"\(regex)\"\(options)}}}"
    }

    // The grid writes a date's milliseconds only when it has them.
    static func expression(field: String) -> String {
        let path = MongoDBQueryBuilder.escapeJsonString("$" + field)
        let types = convertedTypes.map { "\"\($0)\"" }.joined(separator: ", ")
        let branches = [
            "{\"case\": {\"$in\": [{\"$type\": \"$$v\"}, [\(types)]]}, \"then\": {\"$toString\": \"$$v\"}}",
            "{\"case\": {\"$ne\": [{\"$type\": \"$$v\"}, \"date\"]}, \"then\": \"\"}",
            "{\"case\": {\"$lt\": [\"$$v\", \(dateJson(earliestDateMilliseconds))]}, \"then\": \"\"}",
            "{\"case\": {\"$gt\": [\"$$v\", \(dateJson(latestDateMilliseconds))]}, \"then\": \"\"}",
            "{\"case\": {\"$eq\": [{\"$millisecond\": \"$$v\"}, 0]}, \"then\": \(dateText("%Y-%m-%dT%H:%M:%SZ"))}"
        ]
        let choice = "{\"$switch\": {\"branches\": [\(branches.joined(separator: ", "))], "
            + "\"default\": \(dateText("%Y-%m-%dT%H:%M:%S.%LZ"))}}"
        return "{\"$let\": {\"vars\": {\"v\": \"\(path)\"}, \"in\": \(choice)}}"
    }

    private static func dateJson(_ milliseconds: Int64) -> String {
        "{\"$date\": {\"$numberLong\": \"\(milliseconds)\"}}"
    }

    private static func dateText(_ format: String) -> String {
        "{\"$dateToString\": {\"date\": \"$$v\", \"format\": \"\(format)\"}}"
    }
}
