//
//  DocumentPath.swift
//  TableProDocumentPath
//
//  Resolves a dotted path through a decoded JSON document.
//

import Foundation

/// A document store reports an array of objects as its dotted leaves (`variants.sku`,
/// `identifiers.type`) while the document keeps the array intact, so walking dictionaries alone
/// reaches nothing and every value of such a column renders blank.
public enum DocumentPath {
    /// The value at `path`, or nil where nothing along it answers.
    ///
    /// An array is a container rather than a level of the path: the remaining keys are read from
    /// each element and the answers come back as an array of the same length. An element that
    /// lacks the key keeps its place as `NSNull`, so two leaf columns of one array stay aligned
    /// and the third sku still reads as the third variant's.
    public static func value(in document: [String: Any], atPath path: String) -> Any? {
        value(in: document, keys: path.split(separator: ".").map(String.init)[...])
    }

    private static func value(in current: Any, keys: ArraySlice<String>) -> Any? {
        guard let key = keys.first else { return current }
        if let dictionary = current as? [String: Any] {
            guard let next = dictionary[key] else { return nil }
            return value(in: next, keys: keys.dropFirst())
        }
        guard let array = current as? [Any] else { return nil }
        let collected = array.map { value(in: $0, keys: keys) }
        guard collected.contains(where: { $0 != nil }) else { return nil }
        return collected.map { $0 ?? NSNull() }
    }
}
