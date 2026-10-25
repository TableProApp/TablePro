//
//  DataTabGridMountStub.swift
//  TableProTests
//

import AppKit

@testable import TablePro

// Stands in for a grid on screen: the coordinator asks a model whether it is mounted, and an open
// cell editor commits through the mounted view.
@MainActor
final class DataTabGridMountStub: DataGridMountedView {
    var isEditing = false
    private(set) var changes: [DataGridChange] = []
    private(set) var commitCount = 0
    private(set) var discardCount = 0
    // Runs when an open editor commits, the way the field editor hands its text to the model.
    var onCommit: (@MainActor () -> Void)?

    func apply(_ change: DataGridChange) {
        changes.append(change)
    }
    func selectionDidChange() {}
    func configurationDidChange() {}
    func reveal(row: Int, displayColumn: Int?) {}
    func revealColumn(_ displayColumn: Int) {}
    func sortDidChange() {}
    func summaryRulesDidChange() {}
    func viewportSample() -> (row: Int, offset: CGFloat)? { nil }
    func beginEditing(row: Int, displayColumn: Int) -> Bool { false }

    func commitEditing() -> Bool {
        commitCount += 1
        if isEditing {
            isEditing = false
            onCommit?()
        }
        return true
    }

    func discardEditing() {
        discardCount += 1
        isEditing = false
    }

    func focus() -> Bool { false }
    func anchor(forColumn displayColumn: Int) -> (view: NSView, rect: NSRect)? { nil }
}
