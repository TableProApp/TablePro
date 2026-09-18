//
//  DataGridView+DisplayInvalidation.swift
//  TablePro
//
//  Throwing away the grid's formatted text when something it was derived from moves.
//

import AppKit
import Combine
import Foundation

extension TableViewCoordinator {
    /// Throws away every formatted string and derives them again. The settings path takes it when
    /// the date format, the NULL text or smart detection moves; the system time zone takes it
    /// because a Unix-timestamp column renders an instant in the reader's own zone.
    func reformatDisplayedText() {
        guard let tableView else { return }
        invalidateDisplayCache()
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        if visibleRange.length > 0 {
            repaintRows(IndexSet(integersIn: visibleRange.location ..< (visibleRange.location + visibleRange.length)))
        }
        startBackgroundPrewarm()
    }

    /// The mounted grid draws again on a zone change. An unmounted tab is covered instead by
    /// `DataGridDisplayIdentity`, which carries the generation, so its cache is replaced rather
    /// than repaired the next time the tab is shown.
    func observeSystemTimeZoneChanges() {
        systemTimeZoneCancellable = AppEvents.shared.systemTimeZoneChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reformatDisplayedText()
            }
    }
}
