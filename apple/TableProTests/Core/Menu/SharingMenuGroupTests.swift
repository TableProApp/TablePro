//
//  SharingMenuGroupTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct SharingMenuGroupTests {
    private func fileMenu() throws -> NSMenu {
        try #require(FileMenuBuilder.build(keyboard: KeyboardSettings()).submenu)
    }

    private func sharingItems(in menu: NSMenu) -> [NSMenuItem] {
        let actions: Set<Selector> = [
            #selector(MainSplitViewController.shareQuery(_:)),
            #selector(MainSplitViewController.shareQueryResult(_:)),
            #selector(AppDelegate.manageSharedLinks(_:))
        ]
        return menu.items.filter {
            $0.identifier == SharingMenuGroup.separatorIdentifier || $0.action.map(actions.contains) == true
        }
    }

    @Test("Off tablepro.app the three share commands and their separator hide, and come back on it")
    func hidesOffProduction() throws {
        let menu = try fileMenu()
        let group = sharingItems(in: menu)
        #expect(group.count == 4)
        let others = menu.items.filter { item in !group.contains { $0 === item } }

        SharingMenuGroup.setShown(false, in: menu)
        #expect(group.allSatisfy { $0.isHidden })
        #expect(others.allSatisfy { !$0.isHidden })

        SharingMenuGroup.setShown(true, in: menu)
        #expect(group.allSatisfy { !$0.isHidden })
    }

    @Test("Sharing follows the server: tablepro.app shares, a company server does not")
    func availabilityFollowsTheServer() {
        #expect(ShareAvailability.isAvailable(in: AccountState()))
        #expect(!ShareAvailability.isAvailable(in: AccountState(server: AccountSettingsContentTests.companyServer)))
    }
}
