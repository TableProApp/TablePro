//
//  SelectionSummaryState.swift
//  TablePro
//

import Combine
import Foundation

/// Only the grid that attached last may write: a tab switch mounts and unmounts grids in no fixed
/// order, and the outgoing grid can still finish a computation after the incoming one attached.
@MainActor
final class SelectionSummaryState: ObservableObject {
    @Published private(set) var summary: SelectionSummary?
    /// False while the figures on screen are being recomputed, so Copy cannot take a stale value.
    @Published private(set) var isCurrent = false
    private var activeOwner: UUID?

    func activate(_ owner: UUID) {
        guard activeOwner != owner else { return }
        activeOwner = owner
        reset()
    }

    func deactivate(_ owner: UUID) {
        guard activeOwner == owner else { return }
        activeOwner = nil
        reset()
    }

    func markPending(from owner: UUID) {
        guard activeOwner == owner, isCurrent else { return }
        isCurrent = false
    }

    func publish(_ summary: SelectionSummary, from owner: UUID) {
        guard activeOwner == owner else { return }
        if self.summary != summary {
            self.summary = summary
        }
        if !isCurrent {
            isCurrent = true
        }
    }

    func clear(from owner: UUID) {
        guard activeOwner == owner else { return }
        reset()
    }

    private func reset() {
        if summary != nil {
            summary = nil
        }
        if isCurrent {
            isCurrent = false
        }
    }
}
