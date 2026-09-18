//
//  StructureViewActionHandler.swift
//  TablePro
//

import Foundation

/// The structure actions that need the grid that is on screen.
///
/// Saving is deliberately absent. The staged edits belong to the tab's `StructureEditingSession`,
/// and the close prompt offers to save them from tabs that have no mounted structure view at all,
/// so `applyStagedChanges` lives on the session and every caller goes there instead.
@MainActor
final class StructureViewActionHandler {
    var previewSQL: (() -> Void)?
    var copyRows: (() -> Void)?
    var pasteRows: (() -> Void)?
    var undo: (() -> Void)?
    var redo: (() -> Void)?
    var addRow: (() -> Void)?
    var removeRow: (() -> Void)?
    var refresh: (() -> Void)?
}
