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
        panel.message = Self.teamCatalogFolderPanelMessage
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        TeamCatalogStorage.folderURL = url
        return url
    }

    static var teamCatalogFolderPanelMessage: String {
        String(
            format: String(
                localized: "Choose a shared folder for your team's connection catalog. Teammates add this folder under Settings > %1$@ > %2$@ to see published connections."
            ),
            SettingsPane.general.title,
            LinkedFoldersSection.title
        )
    }

    private func presentTeamCatalogError(_ error: Error) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Couldn't publish to the team catalog"),
            message: error.localizedDescription,
            window: nil
        )
    }
}
