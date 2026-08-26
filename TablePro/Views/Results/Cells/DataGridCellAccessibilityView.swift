//
//  DataGridCellAccessibilityView.swift
//  TablePro
//

import AppKit

/// Whether anything is reading the data grid through accessibility.
///
/// Accessibility is pull-based, and the first question anyone asks the grid is the app's only signal
/// that a client is attached: `NSWorkspace.isVoiceOverEnabled` covers VoiceOver alone, and nothing
/// at all reports Switch Control, Voice Control, an inspector or XCUITest. So the grid starts in its
/// fast shape and changes shape the first time it is asked.
///
/// One-way and process-wide: a client that attaches once may detach, but nothing reports that
/// either, and dropping back would be a second reload for no gain.
@MainActor
internal enum DataGridAccessibility {
    internal static let didActivateNotification = Notification.Name("com.TablePro.DataGridAccessibilityDidActivate")

    /// Written through `markActive()` in the app. Settable so a test can drive both shapes.
    internal static var isActive = false

    internal static func markActive() {
        guard !isActive else { return }
        isActive = true
        NotificationCenter.default.post(name: didActivateNotification, object: nil)
    }
}

/// A data cell's stand-in for an assistive client, mounted only while one is attached.
///
/// `NSTableView` builds its `AXCell` tree from cell views and from nothing else. An
/// `NSAccessibilityElement` published by the row never reaches that tree, whichever attribute
/// carries the text, whether the attribute is set or overridden, and however the element is
/// parented: the tree shows AppKit's own placeholder in its place, which is why drawn cells read as
/// a full grid of correctly placed, permanently blank values. One view per cell is the cost `#2381`
/// removed, so it is charged only to the sessions that need it.
///
/// The view draws nothing and takes no clicks. Its row still paints every cell and still handles
/// every click, so this carries the text and no pixels.
@MainActor
internal final class DataGridCellAccessibilityView: NSView {
    internal static let reuseIdentifier = NSUserInterfaceItemIdentifier("DataGridCellAccessibilityView")

    private weak var coordinator: TableViewCoordinator?
    private var seededRow = 0
    private var dataColumn = 0

    /// The row this cell is showing now, asked of the table rather than remembered, for the reason
    /// `DataGridRowView.rowIndex` is: an incremental insert or remove moves a mounted cell view to
    /// its new slot without asking for it again, so a stored index outlives the row it named and the
    /// cell then speaks a different row's value under the old row's number.
    private var row: Int {
        guard let tableView = coordinator?.tableView else { return seededRow }
        let resolved = tableView.row(for: self)
        return resolved >= 0 ? resolved : seededRow
    }

    internal func configure(coordinator: TableViewCoordinator, row: Int, dataColumn: Int) {
        self.coordinator = coordinator
        seededRow = row
        self.dataColumn = dataColumn
        setAccessibilityColumnIndexRange(NSRange(location: dataColumn, length: 1))
    }

    /// Answered live for the same reason, rather than stamped in `configure`, so a client reading the
    /// tree after a row moved is told where the cell is rather than where it was built.
    override internal func accessibilityRowIndexRange() -> NSRange {
        NSRange(location: row, length: 1)
    }

    override internal func hitTest(_ point: NSPoint) -> NSView? { nil }

    override internal func isAccessibilityElement() -> Bool { true }

    /// Static text inside the `AXCell` that `NSTableView` wraps every cell view in, which is the
    /// shape the row-number column already publishes and the one VoiceOver expects of a table.
    override internal func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override internal func accessibilityValue() -> Any? { text }

    override internal func accessibilityLabel() -> String? {
        String(
            format: String(localized: "Row %d, column %d: %@"),
            row + 1,
            dataColumn + 1,
            text
        )
    }

    /// Read through rather than stored, so an edit, an undo or a display-format change is spoken
    /// without anything having to remember to stand this view down.
    private var text: String {
        coordinator?.accessibilityText(row: row, columnIndex: dataColumn) ?? ""
    }
}
