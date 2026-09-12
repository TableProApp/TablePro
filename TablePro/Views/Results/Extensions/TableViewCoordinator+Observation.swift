//
//  TableViewCoordinator+Observation.swift
//  TablePro
//

import AppKit
import Combine

internal extension TableViewCoordinator {
    func applyDataGridSettingsChange(from previous: DataGridSettings, to settings: DataGridSettings) {
        guard let tableView else { return }
        let newRowHeight = CGFloat(settings.rowHeight.rawValue)
        if tableView.rowHeight != newRowHeight {
            tableView.rowHeight = newRowHeight
            tableView.tile()
            repaintRowGutter()
        }

        let dataChanged = previous.dateFormat != settings.dateFormat
            || previous.nullDisplay != settings.nullDisplay
            || previous.enableSmartValueDetection != settings.enableSmartValueDetection

        if dataChanged {
            reformatDisplayedText()
        }
    }

    func observeThemeChanges() {
        themeCancellable = AppEvents.shared.themeChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                if let tableView = self?.tableView {
                    DataGridBodyChrome.applyBackground(to: tableView)
                    tableView.headerView?.needsDisplay = true
                    tableView.cornerView?.needsDisplay = true
                }
                self?.reloadVisibleRowsAndStates()
                /// The row-number font is a theme value and it decides the column's width, which
                /// the pinned gutter mirrors. Nothing re-measured it on a theme change before, so
                /// the width was already going stale here.
                self?.resizeRowNumberColumnForCurrentRange()
                self?.repaintRowGutter()
                self?.selectionController.overlay?.needsDisplay = true
            }
    }

    /// The grid mounts no view for a data cell, so a client that attaches mid-session finds a table
    /// of empty cells until the visible rows are built again. The remount is deferred off the
    /// accessibility query that raised the flag, because rebuilding rows inside it would re-enter
    /// the tree AppKit is walking.
    func observeAccessibilityActivation() {
        accessibilityActivationObserver = NotificationCenter.default.addObserver(
            forName: DataGridAccessibility.didActivateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.remountAccessibilityCells()
            }
        }
    }

    /// Registered for the life of the coordinator, so it has to come off when the grid goes.
    ///
    /// `NotificationCenter` retains a block observer's closure, and a coordinator is built fresh on
    /// every mount, so an entry left behind at teardown is never fired again and never reclaimed.
    /// The closure captures `self` weakly, so this leaks the registration rather than the grid.
    func detachAccessibilityActivationObserver() {
        guard let accessibilityActivationObserver else { return }
        NotificationCenter.default.removeObserver(accessibilityActivationObserver)
        self.accessibilityActivationObserver = nil
    }

    var hasAccessibilityActivationObserver: Bool { accessibilityActivationObserver != nil }
}
