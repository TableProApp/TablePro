//
//  MainContentCoordinator+SheetGate.swift
//  TablePro
//

import AppKit
import os

internal extension MainContentCoordinator {
    nonisolated private static var sheetGateLogger: Logger {
        Logger(subsystem: "com.TablePro", category: "SheetGate")
    }

    // The window sees every presenter (AppKit, other SwiftUI sheets, another hosted connection); `activeSheet` sees the turn before SwiftUI attaches it.
    var isPresentingSheet: Bool {
        activeSheet != nil || favoriteDialogQuery != nil || fileConflictRequest != nil
            || workspaceWindow?.attachedSheet != nil
    }

    // `.sheet(item:)` swaps the sheet on screen, so a job it runs would go on with no progress sheet.
    func admitsSheetCommand(_ command: String = #function) -> Bool {
        guard isPresentingSheet else { return true }
        Self.sheetGateLogger.info("Refused \(command, privacy: .public): the window has a sheet attached")
        return false
    }
}
