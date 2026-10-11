//
//  WelcomeViewModelTeamCatalogTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct WelcomeViewModelTeamCatalogTests {
    @Test("The catalog folder panel names the Settings pane Linked Folders lives in")
    func folderPanelNamesTheGeneralPane() {
        let message = WelcomeViewModel.teamCatalogFolderPanelMessage
        let path = "Settings > \(SettingsPane.general.title) > \(LinkedFoldersSection.title)"

        #expect(message.contains(path))
    }
}
