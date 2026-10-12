//
//  MongoNestedValueDiff.swift
//  MongoDBDriverPlugin
//

import Foundation

/// The field paths an edit of a nested document or array changed, so a save writes those and
/// leaves every other embedded value as the server holds it.
///
/// Writing the whole value back would send every untouched key through JavaScript, which lists
/// number-like keys first, and would overwrite what another client changed beside the edit. A path
/// is only used where the server applies it exactly: a key that cannot be addressed by a path, an
/// array whose length changed, a value whose type changed, or keys the server would append in an
/// order the edit did not write all fall back to writing the nearest enclosing value whole.
enum MongoNestedValueDiff {
    typealias Value = MongoDocumentText.Value
    typealias Member = MongoDocumentText.Member

    enum Change: Equatable {
        case set(path: String, value: Value)
        case remove(path: String)
    }

    static func changes(from old: Value, to new: Value, at path: String) -> [Change] {
        guard old != new else { return [] }
        switch (old, new) {
        case (.object(let oldMembers), .object(let newMembers)):
            guard !MongoExtendedJsonForm.isWrapper(oldMembers), !MongoExtendedJsonForm.isWrapper(newMembers),
                  let changes = memberChanges(from: oldMembers, to: newMembers, at: path) else {
                return [.set(path: path, value: new)]
            }
            return changes
        case (.array(let oldElements), .array(let newElements)) where oldElements.count == newElements.count:
            return zip(oldElements, newElements).enumerated().flatMap { index, pair in
                changes(from: pair.0, to: pair.1, at: "\(path).\(index)")
            }
        default:
            return [.set(path: path, value: new)]
        }
    }

    /// Nil when the edit cannot be expressed key by key, which writes the object whole.
    ///
    /// The server keeps an existing key where it is and appends a new one at the end, and several
    /// new keys in one update land in its own order rather than the one written, so more than one
    /// new key is written as the whole object.
    private static func memberChanges(from old: [Member], to new: [Member], at path: String) -> [Change]? {
        let oldKeys = old.map(\.key)
        let newKeys = new.map(\.key)
        let newKeySet = Set(newKeys)
        let oldKeySet = Set(oldKeys)
        let added = newKeys.filter { !oldKeySet.contains($0) }
        guard added.count <= 1 else { return nil }
        guard oldKeys.filter(newKeySet.contains) + added == newKeys else { return nil }

        var changes: [Change] = []
        for key in oldKeys where !newKeySet.contains(key) {
            guard BsonDocumentFlattener.isAddressableSegment(key) else { return nil }
            changes.append(.remove(path: "\(path).\(key)"))
        }
        for member in new {
            let oldValue = old.first { $0.key == member.key }?.value
            guard oldValue != member.value else { continue }
            guard BsonDocumentFlattener.isAddressableSegment(member.key) else { return nil }
            let memberPath = "\(path).\(member.key)"
            guard let oldValue else {
                changes.append(.set(path: memberPath, value: member.value))
                continue
            }
            changes += Self.changes(from: oldValue, to: member.value, at: memberPath)
        }
        return changes
    }
}
