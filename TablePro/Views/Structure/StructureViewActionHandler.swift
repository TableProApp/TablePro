//
//  StructureViewActionHandler.swift
//  TablePro
//

import Foundation

@MainActor
final class StructureViewActionHandler {
    var saveChanges: (() -> Void)?
    var previewSQL: (() -> Void)?
    var copyRows: (() -> Void)?
    var pasteRows: (() -> Void)?
    var undo: (() -> Void)?
    var redo: (() -> Void)?
    var addRow: (() -> Void)?
    var removeRow: (() -> Void)?
    var refresh: (() -> Void)?
}
