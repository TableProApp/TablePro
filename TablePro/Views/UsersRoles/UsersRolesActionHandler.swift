import Foundation

@MainActor
final class UsersRolesActionHandler {
    var hasChanges: () -> Bool = { false }
    var canUndo: () -> Bool = { false }
    var canRedo: () -> Bool = { false }
    var undoMenuTitle: () -> String = { String(localized: "Undo") }
    var redoMenuTitle: () -> String = { String(localized: "Redo") }

    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var addPrincipal: () -> Void = {}
    var dropSelected: () -> Void = {}
    var discard: () -> Void = {}
    var reviewAndApply: () -> Void = {}
    var previewSQL: () -> Void = {}
    var refresh: () -> Void = {}
}
