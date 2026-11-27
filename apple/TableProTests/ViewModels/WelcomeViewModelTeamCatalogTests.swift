import Foundation
@testable import TablePro
import Testing

@MainActor
struct WelcomeViewModelTeamCatalogTests {
    @Test("The catalog folder panel names the Settings pane and page Linked Folders lives in")
    func folderPanelNamesTheConnectionsPage() {
        let message = WelcomeViewModel.teamCatalogFolderPanelMessage
        let path = "Settings > \(SettingsPane.connections.title) > \(SettingsPage.linkedFolders.title)"

        #expect(message.contains(path))
    }
}
