//
//  WelcomeViewModel+ProjectFolder.swift
//  TablePro
//

import AppKit
import os

extension WelcomeViewModel {
    private static let projectFolderLogger = Logger(
        subsystem: "com.TablePro",
        category: "WelcomeProjectFolder"
    )

    func openProjectFolder() {
        Task { @MainActor in
            await presentProjectFolderPicker()
        }
    }

    @MainActor
    private func presentProjectFolderPicker() async {
        guard let window = Self.hostWindow() else {
            Self.projectFolderLogger.error("No window available to present the project folder picker")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose Folder")
        panel.message = String(localized: "Choose a project folder to read its database settings.")
        let response = await panel.presentAsSheet(for: window)
        guard response == .OK, let url = panel.url else {
            return
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        activeSheet = .projectFolderScan(url)
    }

    static func hostWindow() -> NSWindow? {
        if let key = NSApp.keyWindow {
            return key
        }
        if let main = NSApp.mainWindow {
            return main
        }
        return NSApp.windows.first { $0.isVisible }
    }
}
