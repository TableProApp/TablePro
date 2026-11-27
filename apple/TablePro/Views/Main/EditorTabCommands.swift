//
//  EditorTabCommands.swift
//  TablePro
//

import AppKit
import Foundation

internal struct EditorTabCommands {
    internal let connectionId: UUID
    internal let activate: (UUID) -> Void
    internal let newTab: () -> Void
    internal let keepOpen: (UUID) -> Void
    internal let canKeepOpen: (UUID) -> Bool
    internal let isPinned: (UUID) -> Bool
    internal let setPinned: (UUID, Bool) -> Void
    internal let canRename: (UUID) -> Bool
    internal let renameSeed: (UUID) -> EditorTabRenameSeed?
    internal let beginRename: (UUID) -> Void
    // Returns the title the model settled on, so the label never shows the old name for a turn; nil once the tab is gone.
    internal let rename: (UUID, String) -> String?
    internal let close: (UUID) -> Void
    internal let closeOthers: (UUID) -> Void
    internal let canCloseOthers: (UUID) -> Bool
    internal let closeAll: () -> Void
    internal let canCloseAll: () -> Bool
    internal let moveTab: (UUID, Int) -> Void
    internal let canMove: (UUID, Int) -> Bool
    internal let moveBy: (UUID, Int) -> Void
    // The screen point a dragged tab was dropped at, nil when the menu asked.
    internal let tearOff: (UUID, NSPoint?) -> Void
    internal let canTearOff: (UUID) -> Bool
    internal let receiveTab: (UUID, Int) -> Bool
    internal let isOverTabStrip: (NSPoint) -> Bool
    internal let moveToConnection: (UUID) -> Void
    internal let offersMoveToConnection: (UUID) -> Bool
    internal let canMoveToConnection: (UUID) -> Bool
}

internal struct EditorTabRenameSeed: Equatable {
    internal let text: String
    // The automatic name, which an emptied field returns the tab to.
    internal let placeholder: String
}
