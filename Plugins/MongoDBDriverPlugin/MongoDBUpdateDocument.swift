//
//  MongoDBUpdateDocument.swift
//  MongoDBDriverPlugin
//

import Foundation

/// The update a grid edit sends to `updateOne`.
///
/// An ordinary edit is a classic `$set`/`$unset` document, which every server version reads. The
/// server reads each key of that document as a path, though, so a field whose own name holds a dot,
/// starts with `$` or is empty cannot be named there, and `__proto__` never reaches the server at
/// all because the statement is a JavaScript object. A row that touches such a field is sent as an
/// aggregation pipeline instead, which names it with `$setField` or `$unsetField` (MongoDB 5.0).
///
/// Inside a pipeline a dotted path means something else: `$set` of `tags.1` rewrites every element
/// of `tags` rather than the second one, and still reports success. So a pipeline only ever writes
/// whole top-level fields, and every value in it is wrapped in `$literal`, which keeps a string
/// such as `"$price"` or an object shaped like an operator from being evaluated.
enum MongoDBUpdateDocument {
    enum FieldWrite: Equatable {
        case set(field: String, json: String)
        case remove(field: String)

        var field: String {
            switch self {
            case .set(let field, _), .remove(let field): return field
            }
        }
    }

    static func needsFieldExpression(_ field: String) -> Bool {
        !BsonDocumentFlattener.isAddressableSegment(field) || field == "__proto__"
    }

    static func classic(sets: [(path: String, json: String)], removals: [String]) -> String {
        var parts: [String] = []
        if !sets.isEmpty {
            let entries = sets.sorted { $0.path < $1.path }.map { "\(MongoDocumentText.quoted($0.path)): \($0.json)" }
            parts.append("\"$set\": {\(entries.joined(separator: ", "))}")
        }
        if !removals.isEmpty {
            let entries = removals.sorted().map { "\(MongoDocumentText.quoted($0)): \"\"" }
            parts.append("\"$unset\": {\(entries.joined(separator: ", "))}")
        }
        return "{\(parts.joined(separator: ", "))}"
    }

    static func pipeline(_ writes: [FieldWrite]) -> String {
        var stages: [String] = []
        let plainSets = writes.compactMap { write -> String? in
            guard case .set(let field, let json) = write, !needsFieldExpression(field) else { return nil }
            return "\(MongoDocumentText.quoted(field)): {\"$literal\": \(json)}"
        }
        if !plainSets.isEmpty {
            stages.append("{\"$set\": {\(plainSets.joined(separator: ", "))}}")
        }
        let plainRemovals = writes.compactMap { write -> String? in
            guard case .remove(let field) = write, !needsFieldExpression(field) else { return nil }
            return MongoDocumentText.quoted(field)
        }
        if !plainRemovals.isEmpty {
            stages.append("{\"$unset\": [\(plainRemovals.joined(separator: ", "))]}")
        }
        for write in writes where needsFieldExpression(write.field) {
            stages.append(fieldExpressionStage(write))
        }
        return "[\(stages.joined(separator: ", "))]"
    }

    private static func fieldExpressionStage(_ write: FieldWrite) -> String {
        let name = "\"field\": {\"$literal\": \(MongoDocumentText.quoted(write.field))}, \"input\": \"$$ROOT\""
        switch write {
        case .set(_, let json):
            return "{\"$replaceWith\": {\"$setField\": {\(name), \"value\": {\"$literal\": \(json)}}}}"
        case .remove:
            return "{\"$replaceWith\": {\"$unsetField\": {\(name)}}}"
        }
    }
}
