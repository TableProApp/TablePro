//
//  MongoFilterFields.swift
//  MongoDBDriverPlugin
//

import Foundation

// The fields a find's filter document reads: every key that is not an operator, at any depth, and every `$`-prefixed
// path an expression names. Wider than exact on purpose, since it only decides which fields a page keeps its learned
// kinds for, and each dotted path also names its top-level field.
nonisolated enum MongoFilterFields {
    static func named(in filterJson: String) -> Set<String> {
        guard let filter = MongoJsonValue.parse(filterJson) else { return [] }
        var fields = Set<String>()
        collect(filter, into: &fields)
        return fields
    }

    private static func collect(_ value: Any, into fields: inout Set<String>) {
        if let object = value as? [String: Any] {
            guard !MongoJsonValue.isWrapper(object) else { return }
            for (key, child) in object {
                if !key.hasPrefix("$") {
                    insert(key, into: &fields)
                }
                collect(child, into: &fields)
            }
        } else if let array = value as? [Any] {
            for element in array {
                collect(element, into: &fields)
            }
        } else if let text = value as? String, text.hasPrefix("$"), !text.hasPrefix("$$") {
            insert(String(text.dropFirst()), into: &fields)
        }
    }

    private static func insert(_ path: String, into fields: inout Set<String>) {
        guard !path.isEmpty else { return }
        fields.insert(path)
        if let first = path.split(separator: ".", omittingEmptySubsequences: false).first {
            fields.insert(String(first))
        }
    }
}
