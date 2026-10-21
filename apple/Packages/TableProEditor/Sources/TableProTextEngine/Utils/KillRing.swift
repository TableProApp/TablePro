//
//  KillRing.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 6/13/24.
//

import Foundation

// Emacs semantics: https://www.gnu.org/software/emacs/manual/html_node/emacs/Appending-Kills.html
// Each entry holds one string per cursor.
final class KillRing {
    static let shared = KillRing()

    private static let bufferSizeKey = "NSTextKillRingSize"
    // Emacs's `kill-ring-max`. Cocoa's default of one entry leaves yank-pop nothing to cycle.
    static let defaultCapacity = 120

    // The view as an edit left it. A kill or yank continues the previous one only while nothing
    // moved or changed in between.
    struct Continuation: Equatable {
        let owner: ObjectIdentifier
        let selectionChangeCount: Int
        let length: Int
    }

    enum Direction {
        case forward
        case backward
    }

    struct Yank {
        let continuation: Continuation
        let ranges: [NSRange]
    }

    let capacity: Int
    private(set) var entries: [[String]] = []
    private var yankIndex = 0
    private var lastKill: Continuation?
    private var lastYank: Yank?

    init(_ size: Int? = nil) {
        // swiftlint:disable:next storage_environment_defaults
        let configured = UserDefaults.standard.integer(forKey: Self.bufferSizeKey)
        capacity = max(1, size ?? (configured > 0 ? configured : Self.defaultCapacity))
    }

    func kill(_ strings: [String], direction: Direction, before: Continuation?, after: Continuation) {
        defer {
            lastKill = after
            lastYank = nil
            yankIndex = 0
        }
        if let before, before == lastKill, let newest = entries.first, newest.count == strings.count {
            entries[0] = zip(newest, strings).map { old, new in
                direction == .forward ? old + new : new + old
            }
            return
        }
        entries.insert(strings, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    func yank() -> [String] {
        entries.isEmpty ? [] : entries[yankIndex]
    }

    // Steps the yank pointer to the next older entry, wrapping to the newest.
    func rotate() -> [String] {
        guard !entries.isEmpty else { return [] }
        yankIndex = (yankIndex + 1) % entries.count
        return entries[yankIndex]
    }

    func didYank(_ yank: Yank) {
        lastYank = yank
        lastKill = nil
    }

    func yank(continuing continuation: Continuation) -> Yank? {
        guard let lastYank, lastYank.continuation == continuation else { return nil }
        return lastYank
    }
}
