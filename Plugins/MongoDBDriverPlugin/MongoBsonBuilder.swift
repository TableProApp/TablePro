//
//  MongoBsonBuilder.swift
//  MongoDBDriverPlugin
//

#if canImport(CLibMongoc)
import CLibMongoc
import Foundation

/// Builds the BSON document `MongoBsonAssembly` plans for one JSON text.
///
/// Kept apart from `MongoDBConnection` so `scripts/check-mongodb-filter-shapes.sh` compiles this
/// same code against the libbson the plugin links, rather than a copy of what it is meant to do.
enum MongoBsonBuilder {
    /// A new document the caller destroys, or nil after `onParseFailure` has been given libbson's
    /// reason for the text it refused.
    static func document(from json: String, onParseFailure: (String) -> Void = { _ in }) -> OpaquePointer? {
        switch MongoBsonAssembly.plan(json) {
        case .whole(let text):
            return parsed(text, onParseFailure: onParseFailure)
        case .parts(let parts):
            return assembled(parts, onParseFailure: onParseFailure)
        }
    }

    static func errorMessage(_ error: inout bson_error_t) -> String {
        withUnsafePointer(to: &error.message) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 504) { String(cString: $0) }
        }
    }

    private static func parsed(_ json: String, onParseFailure: (String) -> Void) -> OpaquePointer? {
        var error = bson_error_t()
        let document = json.withCString { bson_new_from_json($0, -1, &error) }
        if document == nil {
            onParseFailure(errorMessage(&error))
        }
        return document
    }

    private static func assembled(
        _ parts: [MongoBsonAssembly.Part],
        onParseFailure: (String) -> Void
    ) -> OpaquePointer? {
        guard let document = bson_new() else { return nil }
        for part in parts {
            guard append(part, to: document, onParseFailure: onParseFailure) else {
                bson_destroy(document)
                return nil
            }
        }
        return document
    }

    /// A key is passed with its length, so one holding a NUL is refused rather than cut short.
    private static func append(
        _ part: MongoBsonAssembly.Part,
        to document: OpaquePointer,
        onParseFailure: (String) -> Void
    ) -> Bool {
        switch part {
        case .member(let json):
            guard let member = parsed(json, onParseFailure: onParseFailure) else { return false }
            defer { bson_destroy(member) }
            return bson_concat(document, member)
        case .document(let key, let parts):
            guard let child = assembled(parts, onParseFailure: onParseFailure) else { return false }
            defer { bson_destroy(child) }
            return key.withCString { bson_append_document(document, $0, Int32(key.utf8.count), child) }
        case .array(let key, let parts):
            guard let child = assembled(parts, onParseFailure: onParseFailure) else { return false }
            defer { bson_destroy(child) }
            return key.withCString { bson_append_array(document, $0, Int32(key.utf8.count), child) }
        }
    }
}
#endif
