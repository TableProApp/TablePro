//
//  CatalogFreshness.swift
//  TablePro
//

import Foundation

/// Which cached lists a catalog change has overtaken, for a cache that refetches when it is next
/// read rather than the moment the catalog changes.
///
/// A change moves its key's revision, and a fetch carries the revision it started under. A fetch
/// that was already running when the change landed still delivers its rows, but it cannot make
/// the key current again, so the next read fetches once more. A key whose fetch failed was never
/// committed, which leaves it stale and retried on the next read too.
struct CatalogFreshness<Key: Hashable> {
    private var revisions: [Key: Int] = [:]
    private var committed: [Key: Int] = [:]

    func revision(for key: Key) -> Int {
        revisions[key, default: 0]
    }

    func isCurrent(_ key: Key) -> Bool {
        committed[key] == revision(for: key)
    }

    mutating func markChanged(_ key: Key) {
        revisions[key, default: 0] &+= 1
    }

    /// False when a fetch that started later has already committed, so an older fetch finishing
    /// last cannot put its rows back over newer ones.
    mutating func commit(_ revision: Int, for key: Key) -> Bool {
        if let current = committed[key], current > revision { return false }
        committed[key] = revision
        return true
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        revisions = revisions.filter { !shouldRemove($0.key) }
        committed = committed.filter { !shouldRemove($0.key) }
    }
}
