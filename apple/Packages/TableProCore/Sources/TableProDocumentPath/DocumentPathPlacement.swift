//
//  DocumentPathPlacement.swift
//  TableProDocumentPath
//
//  Builds the partial document that sets one leaf of a stored JSON document.
//

import Foundation

public enum DocumentPathPlacement {
    public struct InsideArray: Error, Equatable {
        public let path: String
    }

    @discardableResult
    public static func set(_ value: Any, atKeys keys: [String], in document: inout [String: Any]) -> Bool {
        guard let key = keys.first else { return false }
        guard keys.count > 1 else {
            document[key] = value
            return true
        }
        var child: [String: Any]
        switch document[key] {
        case nil:
            child = [:]
        case let existing as [String: Any]:
            child = existing
        default:
            return false
        }
        guard set(value, atKeys: Array(keys.dropFirst()), in: &child) else { return false }
        document[key] = child
        return true
    }

    public static func value(in document: [String: Any], atKeys keys: [String]) -> Any? {
        var current: Any = document
        for key in keys {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else { return nil }
            current = next
        }
        return keys.isEmpty ? nil : current
    }

    // A stored document can spell one field as nested objects, as a literal dotted key, or as a
    // mix, and a merge matches keys literally. The value goes to every spelling the document
    // already holds; a field it does not hold yet is added under the deepest object that exists,
    // split where `keys` splits.
    public static func place(
        _ value: Any,
        atKeys keys: [String],
        in partial: inout [String: Any],
        following stored: [String: Any]
    ) throws {
        var atoms: [String] = []
        var boundaries: Set<Int> = []
        for key in keys {
            atoms.append(contentsOf: key.split(separator: ".", omittingEmptySubsequences: false).map(String.init))
            boundaries.insert(atoms.count)
        }
        guard !atoms.isEmpty else { return }
        let path = atoms.joined(separator: ".")

        let spellings = try storedSpellings(of: atoms[...], in: stored, path: path)
        guard spellings.isEmpty else {
            for spelling in spellings {
                set(value, atKeys: spelling, in: &partial)
            }
            return
        }

        var consumed: [String] = []
        var start = 0
        var level = stored
        while let step = firstObject(in: level, atoms: atoms, from: start) {
            consumed.append(step.key)
            start = step.end
            level = step.object
        }

        var group: [String] = []
        for index in start..<atoms.count {
            group.append(atoms[index])
            if boundaries.contains(index + 1) {
                consumed.append(group.joined(separator: "."))
                group = []
            }
        }
        set(value, atKeys: consumed, in: &partial)
    }

    private static func storedSpellings(
        of atoms: ArraySlice<String>,
        in level: [String: Any],
        path: String
    ) throws -> [[String]] {
        var spellings: [[String]] = []
        for end in atoms.indices.map({ $0 + 1 }) {
            let key = atoms[atoms.startIndex..<end].joined(separator: ".")
            guard let found = level[key] else { continue }
            if end == atoms.endIndex {
                spellings.append([key])
            } else if let object = found as? [String: Any] {
                spellings += try storedSpellings(of: atoms[end...], in: object, path: path).map { [key] + $0 }
            } else if let array = found as? [Any], array.contains(where: { $0 is [String: Any] }) {
                throw InsideArray(path: path)
            }
        }
        return spellings
    }

    private static func firstObject(
        in level: [String: Any],
        atoms: [String],
        from start: Int
    ) -> (key: String, end: Int, object: [String: Any])? {
        guard start < atoms.count - 1 else { return nil }
        for end in (start + 1)..<atoms.count {
            let key = atoms[start..<end].joined(separator: ".")
            if let object = level[key] as? [String: Any] {
                return (key, end, object)
            }
        }
        return nil
    }
}
