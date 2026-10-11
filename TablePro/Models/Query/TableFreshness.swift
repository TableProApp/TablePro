//
//  TableFreshness.swift
//  TablePro
//

import Foundation

/// How far a table tab's rows and definition trail the changes announced for its table.
///
/// A change is stamped when it is announced, after its write has finished, and a read with the
/// moment its query claimed the tab. A read covers a change only when it started after it: a load
/// already running when the change lands may have read the table before the write, so committing
/// it leaves the mark in place. A definition is covered only by a read that fetched the definition
/// itself, because a load that reused the metadata it already held carries the old keys, defaults
/// and generated columns into the new result.
struct TableFreshness: Equatable {
    struct Change: Equatable, Sendable {
        enum Extent: Equatable, Sendable {
            case rows
            /// The columns, keys or constraints changed, and with them possibly the rows.
            case definition
        }

        let extent: Extent
        let at: ContinuousClock.Instant
    }

    struct Read: Equatable, Sendable {
        let startedAt: ContinuousClock.Instant
        let includesDefinition: Bool
    }

    private(set) var rowsChangedAt: ContinuousClock.Instant?
    private(set) var definitionChangedAt: ContinuousClock.Instant?

    var isStale: Bool {
        rowsChangedAt != nil || definitionChangedAt != nil
    }

    var needsDefinition: Bool {
        definitionChangedAt != nil
    }

    /// What a read still has to answer: the latest change marked, as a definition change while one
    /// is outstanding. Nil when nothing is.
    var pendingChange: Change? {
        guard let at = rowsChangedAt ?? definitionChangedAt else { return nil }
        return Change(extent: needsDefinition ? .definition : .rows, at: at)
    }

    mutating func record(_ change: Change) {
        rowsChangedAt = Self.later(rowsChangedAt, change.at)
        if change.extent == .definition {
            definitionChangedAt = Self.later(definitionChangedAt, change.at)
        }
    }

    /// Whether a definition fetched by a read that started at `startedAt` describes the table after
    /// every definition change marked, rather than before the latest one.
    func definitionIsCurrent(asOf startedAt: ContinuousClock.Instant) -> Bool {
        guard let definitionChangedAt else { return true }
        return definitionChangedAt <= startedAt
    }

    /// Answers whether the read covered a change to the rows, which is what makes every total
    /// derived before it stale too.
    @discardableResult
    mutating func record(_ read: Read) -> Bool {
        var answeredRows = false
        if let changedAt = rowsChangedAt, changedAt <= read.startedAt {
            rowsChangedAt = nil
            answeredRows = true
        }
        if read.includesDefinition, definitionIsCurrent(asOf: read.startedAt) {
            definitionChangedAt = nil
        }
        return answeredRows
    }

    /// Whether a query already running when `change` is recorded, claimed at `startedAt`, reads what
    /// the change wrote. Never for a definition: that query chose its metadata before the mark existed.
    static func inFlightRead(startedAt: ContinuousClock.Instant, covers change: Change) -> Bool {
        change.extent == .rows && change.at <= startedAt
    }

    private static func later(
        _ current: ContinuousClock.Instant?,
        _ candidate: ContinuousClock.Instant
    ) -> ContinuousClock.Instant {
        guard let current else { return candidate }
        return max(current, candidate)
    }
}
