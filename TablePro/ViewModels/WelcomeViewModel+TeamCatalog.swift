//
//  WelcomeViewModel+TeamCatalog.swift
//  TablePro
//
//  Publishing connections to the shared team catalog.
//

import AppKit

extension WelcomeViewModel {
    func publishToTeamCatalog(_ connectionsToPublish: [DatabaseConnection]) {
        guard LicenseManager.shared.isFeatureAvailable(.teamCatalog),
              !connectionsToPublish.isEmpty,
              let folderURL = resolveTeamCatalogFolder() else {
            return
        }

        do {
            let written = try TeamCatalogPublisher.publish(connectionsToPublish, to: folderURL)
            if !written.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(written)
            }
        } catch {
            presentTeamCatalogError(error)
        }
    }

    private func resolveTeamCatalogFolder() -> URL? {
        if let saved = TeamCatalogStorage.folderURL,
           FileManager.default.fileExists(atPath: saved.path) {
            return saved
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose Folder")
        panel.message = String(
            localized: "Choose a shared folder for your team's connection catalog. Teammates add this folder under Settings > Linked Folders to see published connections."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        TeamCatalogStorage.folderURL = url
        return url
    }

    private func presentTeamCatalogError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't publish to the team catalog")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
