//
//  MainContentCoordinator+RowImport.swift
//  TablePro
//

import AppKit
import Foundation

internal extension ActiveSheet {
    var carriesImportFile: Bool {
        switch self {
        case .importDialog, .rowImport:
            return true
        default:
            return false
        }
    }
}

internal extension MainContentCoordinator {
    func rowImportRefusal(formatId: String) -> RowImportRefusal? {
        RowImportEligibility.refusal(
            formatId: formatId,
            databaseType: connection.type,
            connectionName: connection.name,
            safeModeLevel: safeModeLevel,
            isPresentingSheet: activeSheet != nil || workspaceWindow?.attachedSheet != nil,
            lookup: importFormatLookup
        )
    }

    @discardableResult
    func presentRowImport(of fileURL: URL, formatId: String, ownsFile: Bool) -> RowImportRefusal? {
        if let refusal = rowImportRefusal(formatId: formatId) {
            if case .importNotSupported = refusal {
                revealWorkspace()
                reportImportRefusal(refusal)
            }
            return refusal
        }
        revealWorkspace()
        releaseImportFile()
        importFile = ImportFileHandoff(url: fileURL, ownsFile: ownsFile)
        activeSheet = .rowImport(formatId: formatId)
        return nil
    }

    func reportImportRefusal(_ refusal: RowImportRefusal) {
        guard case .importNotSupported = refusal else { return }
        presentError(
            String(localized: "Import Not Supported"),
            refusal.localizedDescription,
            workspaceWindow
        )
    }

    func releaseImportFile() {
        guard let handoff = importFile else { return }
        importFile = nil
        handoff.discard()
    }

    func releaseImportFileUnlessImporting() {
        guard activeSheet?.carriesImportFile != true else { return }
        releaseImportFile()
    }

    private var workspaceWindow: NSWindow? {
        guard let splitViewController, splitViewController.isViewLoaded else { return contentWindow }
        return splitViewController.view.window ?? contentWindow
    }

    private func revealWorkspace() {
        splitViewController?.selectHostedConnection(connectionId)
        WindowManager.shared.bringToFront(workspaceWindow)
    }
}
