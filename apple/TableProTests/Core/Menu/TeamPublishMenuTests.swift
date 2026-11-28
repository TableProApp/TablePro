import AppKit
@testable import TablePro
import Testing

@MainActor
struct TeamPublishMenuTests {
    private let design = TeamLibraryTeam(id: "team-design", name: "Design")
    private let data = TeamLibraryTeam(id: "team-data", name: "Data")

    private func fileMenu() throws -> NSMenu {
        let built = MainMenuBuilder.build(keyboard: KeyboardSettings())
        return try #require(built.bar.items.first { $0.title == String(localized: "File") }?.submenu)
    }

    @Test("File > Publish Saved Queries to Team sits with the sharing commands and is filled when it opens")
    func fileMenuPlacement() throws {
        let file = try fileMenu()
        let item = try #require(file.items.first { $0.identifier == TeamPublishMenuGroup.identifier })
        let manage = try #require(file.items.firstIndex { $0.title == "Manage Shared Links…" })

        #expect(item.title == "Publish Saved Queries to Team")
        #expect(file.items.firstIndex(of: item) == manage + 1)
        #expect(item.submenu?.delegate is TeamPublishMenuDelegate)
        #expect(item.submenu?.items.isEmpty == true)
    }

    @Test("Each team this account writes is a row naming the team, carried out through the responder chain")
    func rowsNameTheirTeam() {
        let delegate = TeamPublishMenuDelegate(teams: { [self.data, self.design] })
        let menu = NSMenu()

        delegate.menuNeedsUpdate(menu)

        #expect(menu.items.map(\.title) == ["Data…", "Design…"])
        #expect(menu.items.compactMap { $0.representedObject as? String } == ["team-data", "team-design"])
        #expect(menu.items.allSatisfy { $0.action == #selector(AppDelegate.publishSavedQueriesToTeam(_:)) })
        #expect(menu.items.allSatisfy { $0.target == nil && $0.keyEquivalent.isEmpty })
    }

    @Test("The submenu shows only while the account writes a team's library")
    func shownOnlyWithWritableTeams() throws {
        let file = try fileMenu()
        let item = try #require(file.items.first { $0.identifier == TeamPublishMenuGroup.identifier })

        TeamPublishMenuGroup.update(in: file, teams: [])
        #expect(item.isHidden)

        TeamPublishMenuGroup.update(in: file, teams: [design])
        #expect(!item.isHidden)

        TeamPublishMenuGroup.update(in: file, teams: [])
        #expect(item.isHidden)
    }
}
