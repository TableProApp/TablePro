//
//  StructureViewActionHandler.swift
//  TablePro
//
//  Action handler for structure view — allows coordinator to call
//  structure-view actions directly instead of broadcasting notifications.
//

import Foundation

/// Provides direct action dispatch from coordinator to structure view,
/// replacing notification-based communication.
@MainActor
final class StructureViewActionHandler {
    var saveChanges: (() -> Void)?
    var previewSQL: (() -> Void)?
    var copyRows: (() -> Void)?
    var pasteRows: (() -> Void)?
    var undo: (() -> Void)?
    var redo: (() -> Void)?
}
