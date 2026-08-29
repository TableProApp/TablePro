import Foundation

/// The cursor modifiers a script chains onto `find()` or `aggregate()`.
///
/// Every value arrives from JavaScript as canonical Extended JSON, so it is carried as text and
/// spliced into the options document verbatim. The previous path pushed `sort` and `projection`
/// through `JSONSerialization`, which cannot read Extended JSON and reported failure by returning
/// nil, so a sort the parser had accepted was dropped and the query ran unsorted while reporting
/// success.
struct MongoScriptCursorOptions: Equatable, Sendable {
    var sort: String?
    var projection: String?
    var skip: Int?
    var limit: Int?
    var batchSize: Int?
    var hint: String?
    var collation: String?
    var maxTimeMS: Int?
    var allowDiskUse = false

    static let none = MongoScriptCursorOptions()

    var isMutated: Bool { self != .none }

    mutating func apply(key: String, value: String) throws {
        switch key {
        case "sort": sort = value
        case "projection": projection = value
        case "hint": hint = value
        case "collation": collation = value
        case "limit": limit = try Self.wholeNumber(value, key: key)
        case "skip": skip = try Self.wholeNumber(value, key: key)
        case "batchSize": batchSize = try Self.wholeNumber(value, key: key)
        case "maxTimeMS": maxTimeMS = try Self.wholeNumber(value, key: key)
        case "allowDiskUse": allowDiskUse = true
        default: throw MongoScriptError(MongoScriptText.unsupportedCursorOption(key))
        }
    }

    /// The `find` options document, as text libbson parses directly.
    ///
    /// `limit` is the smaller of what the script asked for and the ceiling the caller imposes, so a
    /// script that asks for more than the row cap still stops at the cap and a script that asks for
    /// fewer is not silently raised to it.
    func findOptionsJson(limit ceiling: Int, timeoutMS: Int32) -> String {
        var fields: [String] = ["\"skip\": \(skip ?? 0)", "\"limit\": \(effectiveLimit(ceiling: ceiling))"]
        appendDocument(&fields, key: "sort", value: sort)
        appendDocument(&fields, key: "projection", value: projection)
        appendDocument(&fields, key: "hint", value: hint)
        appendDocument(&fields, key: "collation", value: collation)
        if let batchSize { fields.append("\"batchSize\": \(batchSize)") }
        if allowDiskUse { fields.append("\"allowDiskUse\": true") }
        if let resolved = resolvedMaxTimeMS(timeoutMS) { fields.append("\"maxTimeMS\": \(resolved)") }
        return "{\(fields.joined(separator: ", "))}"
    }

    func aggregateOptionsJson(timeoutMS: Int32) -> String? {
        var fields: [String] = []
        appendDocument(&fields, key: "hint", value: hint)
        appendDocument(&fields, key: "collation", value: collation)
        if let batchSize { fields.append("\"batchSize\": \(batchSize)") }
        if allowDiskUse { fields.append("\"allowDiskUse\": true") }
        if let resolved = resolvedMaxTimeMS(timeoutMS) { fields.append("\"maxTimeMS\": \(resolved)") }
        guard !fields.isEmpty else { return nil }
        return "{\(fields.joined(separator: ", "))}"
    }

    /// An aggregation takes its ordering and paging as pipeline stages, not as cursor options, so a
    /// `.sort()` chained onto `aggregate()` has to become a `$sort` stage appended after the
    /// script's own stages. Appending rather than prepending is what mongosh does and what the
    /// chaining reads as: the modifier applies to the pipeline's output.
    func decoratedPipeline(_ pipeline: String) -> String {
        var stages: [String] = []
        if let sort { stages.append("{\"$sort\": \(sort)}") }
        if let skip, skip > 0 { stages.append("{\"$skip\": \(skip)}") }
        if let limit, limit > 0 { stages.append("{\"$limit\": \(limit)}") }
        guard !stages.isEmpty else { return pipeline }

        let trimmed = pipeline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return pipeline }
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        let appended = stages.joined(separator: ",")
        return inner.isEmpty ? "[\(appended)]" : "[\(inner),\(appended)]"
    }

    func effectiveLimit(ceiling: Int) -> Int {
        guard let limit, limit > 0 else { return ceiling }
        return ceiling > 0 ? min(limit, ceiling) : limit
    }

    private func resolvedMaxTimeMS(_ timeoutMS: Int32) -> Int? {
        if let maxTimeMS, maxTimeMS > 0 { return maxTimeMS }
        return timeoutMS > 0 ? Int(timeoutMS) : nil
    }

    private func appendDocument(_ fields: inout [String], key: String, value: String?) {
        guard let value, !value.isEmpty, value != "null" else { return }
        fields.append("\"\(key)\": \(value)")
    }

    /// A cursor modifier's numeric argument.
    ///
    /// Refused rather than converted when it is not a whole number: JavaScript reaches NaN and
    /// infinity through ordinary arithmetic, `Double("NaN")` parses, and `Int(Double.nan)` traps.
    private static func wholeNumber(_ value: String, key: String) throws -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Int(trimmed) { return direct }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let parsed = MongoScriptJson.numeric(object),
              let narrowed = Int(exactly: parsed) else {
            throw MongoScriptError(MongoScriptText.wholeNumberExpected(key))
        }
        return narrowed
    }
}
