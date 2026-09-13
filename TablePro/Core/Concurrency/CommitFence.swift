//
//  CommitFence.swift
//  TablePro
//

import Foundation

/// A generation per key, so a load can tell when it finishes whether what it fetched is still the
/// answer for that key.
///
/// Cancelling a fetch does not stop a driver blocked in a C call, and a fetch that began before its
/// key was superseded can return after the fetch that superseded it. A load takes a token when it
/// starts and commits only while that token is current; superseding the key moves it on.
struct CommitFence<Key: Hashable> {
    private var generations: [Key: Int] = [:]

    func token(for key: Key) -> Int {
        generations[key, default: 0]
    }

    func isCurrent(_ token: Int, for key: Key) -> Bool {
        generations[key, default: 0] == token
    }

    /// Returns the token the superseding load commits under.
    @discardableResult
    mutating func supersede(_ key: Key) -> Int {
        generations[key, default: 0] &+= 1
        return generations[key, default: 0]
    }
}
