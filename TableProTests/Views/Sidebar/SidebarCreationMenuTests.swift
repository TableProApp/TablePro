//
//  SidebarCreationMenuTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

@MainActor
struct SidebarCreationMenuTests {
    private func facts(
        table: Bool = true,
        view: Bool = true,
        schema: Bool = true,
        database: Bool = true,
        folders: Bool = true,
        schemaEntityName: String = "Schema"
    ) -> SidebarCreationFacts {
        SidebarCreationFacts(
            canCreateTable: table,
            canCreateView: view,
            supportsCreateSchema: schema,
            supportsCreateDatabase: database,
            offersBrowsedFolders: folders,
            schemaEntityName: schemaEntityName,
            activeDatabase: "app"
        )
    }

    private func commands(_ sections: [DatabaseTreeMenuSection]) -> [SidebarMenuCommand] {
        sections.flatMap(\.items).compactMap { item in
            guard case .command(let entry) = item else { return nil }
            return entry.command
        }
    }

    private func titles(_ sections: [DatabaseTreeMenuSection]) -> [String] {
        sections.flatMap(\.items).compactMap { item in
            guard case .command(let entry) = item else { return nil }
            return entry.title
        }
    }

    private var everyCommand: [SidebarMenuCommand] {
        commands(DatabaseTreeMenuSpec.creationSections(facts(), hidesDatabaseWrites: false))
    }

    @Test("Objects, then containers, then folders, each its own group")
    func groupsInOrder() {
        let sections = DatabaseTreeMenuSpec.creationSections(facts(), hidesDatabaseWrites: false)

        #expect(sections.map { commands([$0]) } == [
            [.createTable, .createView],
            [.createSchema(database: "app"), .createDatabase],
            [.tableFolder(.create(.browsed))]
        ])
    }

    @Test("An item the engine cannot do is left out")
    func capabilityGatesEachItem() {
        let cases: [(SidebarCreationFacts, SidebarMenuCommand)] = [
            (facts(table: false), .createTable),
            (facts(view: false), .createView),
            (facts(schema: false), .createSchema(database: "app")),
            (facts(database: false), .createDatabase),
            (facts(folders: false), .tableFolder(.create(.browsed)))
        ]
        for (input, missing) in cases {
            let issued = commands(DatabaseTreeMenuSpec.creationSections(input, hidesDatabaseWrites: false))
            #expect(!issued.contains(missing), "\(missing) offered without its capability")
            #expect(issued.count == 4)
        }
    }

    @Test("Hiding database writes keeps only New Folder")
    func hidingWritesKeepsFolders() {
        let issued = commands(DatabaseTreeMenuSpec.creationSections(facts(), hidesDatabaseWrites: true))

        #expect(issued == [.tableFolder(.create(.browsed))])
    }

    @Test("The list is empty exactly when no capability holds")
    func listIsEmptyOnlyWithoutCapabilities() {
        for mask in 0..<32 {
            let input = facts(
                table: mask & 1 != 0,
                view: mask & 2 != 0,
                schema: mask & 4 != 0,
                database: mask & 8 != 0,
                folders: mask & 16 != 0
            )
            let isEmpty = DatabaseTreeMenuSpec.creationSections(input, hidesDatabaseWrites: false)
                .nonEmptySections()
                .isEmpty
            #expect(isEmpty == (mask == 0), "mask \(mask)")
        }
    }

    @Test("The schema item uses the engine's noun")
    func schemaItemUsesEngineNoun() {
        let sections = DatabaseTreeMenuSpec.creationSections(
            facts(schemaEntityName: "Dataset"),
            hidesDatabaseWrites: false
        )

        #expect(titles(sections).contains(String(format: String(localized: "New %@…"), "Dataset")))
    }

    @Test("The flat list always offers the add button")
    func flatListOffersCreation() {
        #expect(SidebarCreationFacts.offersAnyCreation(
            connectionId: UUID(),
            databaseType: .sqlite,
            offersBrowsedFolders: true
        ))
    }

    @Test("Every item reaches the window and is decided there")
    func everyItemIsAnsweredAndDecided() {
        #expect(everyCommand.count == 5)
        for command in everyCommand {
            let selector = SidebarCreationMenuBuilder.selector(for: command)
            #expect(selector != nil, "\(command) has no selector")
            guard let selector else { continue }
            let name = NSStringFromSelector(selector)
            #expect(MainSplitViewController.instancesRespond(to: selector), "\(name) reaches nothing")
            #expect(
                MainSplitViewController.resolvedEnablement(selector, context: MenuValidationContext()) != nil,
                "\(name) has no arm, so it stays lit over a window that cannot run it"
            )
        }
    }

    @Test("Read-only dims the database writes and leaves New Folder")
    func readOnlyDimsWritesOnly() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.canCreateTable = true
        context.canCreateView = true
        context.canCreateSchema = true
        context.canCreateDatabase = true
        context.canCreateTableFolder = true
        for command in everyCommand {
            guard let selector = SidebarCreationMenuBuilder.selector(for: command) else { continue }
            #expect(MainSplitViewController.isEnabled(selector, context: context), "\(command)")
        }

        context.isReadOnly = true
        context.canCreateSchema = false
        context.canCreateDatabase = false
        for command in everyCommand {
            guard let selector = SidebarCreationMenuBuilder.selector(for: command) else { continue }
            let expected = command == .tableFolder(.create(.browsed))
            #expect(MainSplitViewController.isEnabled(selector, context: context) == expected, "\(command)")
        }
    }

    @Test("The built menu leaves its items to responder-chain validation")
    func builtMenuUsesTheResponderChain() {
        let menu = NSMenu()
        SidebarCreationMenuBuilder.fill(
            menu,
            with: DatabaseTreeMenuSpec.creationSections(facts(), hidesDatabaseWrites: false)
        )
        let items = menu.items.filter { !$0.isSeparatorItem }

        #expect(menu.autoenablesItems)
        #expect(menu.items.filter(\.isSeparatorItem).count == 2)
        #expect(items.count == 5)
        for item in items {
            #expect(item.target == nil, "\(item.title) carries a target")
            #expect(item.action != nil, "\(item.title) has no action")
        }
        #expect(items.first?.action == #selector(MainSplitViewController.createNewTable(_:)))
        #expect(items.last?.action == #selector(MainSplitViewController.createTableFolder(_:)))
    }

    @Test("The pull-down keeps its symbol item first, enabled and holding no command")
    func pullDownKeepsItsLabelItem() throws {
        let sections = DatabaseTreeMenuSpec.creationSections(facts(), hidesDatabaseWrites: false)
        let button = SidebarPullDownButton(symbolName: "plus", label: "Add", identifier: "sidebar-add") { menu in
            SidebarCreationMenuBuilder.fill(menu, with: sections)
        }
        let menu = try #require(button.menu)
        button.menuNeedsUpdate(menu)
        button.menuNeedsUpdate(menu)

        #expect(button.pullsDown)
        #expect(button.accessibilityIdentifier() == "sidebar-add")
        // AppKit gives an action-less pull-down item its own `_popUpItemAction:`; what matters is
        // that the label item carries none of the creation commands.
        let commandActions: [Selector] = [
            #selector(MainSplitViewController.createNewTable(_:)),
            #selector(MainSplitViewController.createNewView(_:)),
            #selector(MainSplitViewController.createSchema(_:)),
            #selector(MainSplitViewController.createNewDatabase(_:)),
            #selector(MainSplitViewController.createTableFolder(_:))
        ]
        #expect(menu.items.first?.title.isEmpty == true)
        #expect(!commandActions.contains { $0 == menu.items.first?.action })
        #expect(menu.items.first?.image != nil)
        #expect(menu.items.first?.isEnabled == true)
        #expect(menu.items.filter { !$0.isSeparatorItem }.count == 6)
    }
}
