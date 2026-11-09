import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension DatabaseTreeMenuSpecTests {
    private func viewOptionEntries(_ sections: [DatabaseTreeMenuSection]) -> [SidebarMenuEntry<SidebarMenuCommand>] {
        sections.flatMap { $0.items }.compactMap { item -> SidebarMenuEntry<SidebarMenuCommand>? in
            guard case .command(let entry) = item else { return nil }
            return entry
        }
    }

    @Test("View Options lists Table Details right after Partitions, with its own state")
    func viewOptionsOfferTableDetails() {
        let sections = SidebarViewOptionsMenu.sections(
            showObjectIcons: true,
            showObjectComments: true,
            showSystemContainers: true,
            showPartitions: true,
            showTableDetails: false,
            rowSize: .matchSystem
        )
        let toggles = viewOptionEntries(Array(sections.prefix(1)))
        let commands = toggles.map { $0.command }
        let expected: [SidebarMenuCommand] = [
            .toggleObjectIcons, .toggleObjectComments, .toggleSystemContainers, .togglePartitions, .toggleTableDetails
        ]

        #expect(commands == expected)
        #expect(toggles.last?.title == String(localized: "Table Details"))
        #expect(toggles.last?.isOn == false)
    }

    @Test("The empty-area menu reads Table Details from its context")
    func viewOptionsReadTableDetailsFromTheContext() {
        var menuContext = context(clicked: nil)
        menuContext.showTableDetails = true
        let state = viewOptionEntries(SidebarViewOptionsMenu.sections(menuContext))
            .first { $0.command == .toggleTableDetails }?
            .isOn

        #expect(state == true)
    }
}

extension GlobalStateSuites {
    @MainActor
    struct TableDetailsViewOptionsTests {
        @Test(
            "Table Details in View Options starts off and flips the setting",
            .appSettings { $0.general.showTableDetails = false }
        )
        func viewOptionsEntryWritesTheSetting() throws {
            let found = SidebarViewOptionsMenu.currentSections()
                .flatMap { $0.items }
                .lazy
                .compactMap { item -> SidebarMenuEntry<SidebarMenuCommand>? in
                    guard case .command(let entry) = item, entry.command == .toggleTableDetails else { return nil }
                    return entry
                }
                .first
            let entry = try #require(found)
            #expect(entry.isOn == false)

            #expect(SidebarViewOptionsMenu.apply(entry.command))

            #expect(AppSettingsManager.shared.general.showTableDetails)
        }
    }
}
