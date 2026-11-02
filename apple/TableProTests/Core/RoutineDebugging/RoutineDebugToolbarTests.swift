//
//  RoutineDebugToolbarTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct RoutineDebugToolbarTests {
    private static let pair = Set(MainWindowToolbar.debugDefaultItemIdentifiers)

    private static func hidden(
        tabKind: TabType?,
        contentMode: ConnectionWorkspaceContentMode = .browse,
        showsDebugItems: Bool = true
    ) -> Set<NSToolbarItem.Identifier> {
        let context = ToolbarContext(
            tabKind: tabKind,
            contentMode: contentMode,
            pane: .content,
            isConnected: true,
            hasSelectedWorkspace: true,
            supportsContainerSwitching: true,
            showsDebugItems: showsDebugItems
        )
        return ToolbarContextResolver.visibility(for: context.visibilityKey).hidden
    }

    @Test("Continue and Stop sit ahead of the Actions pull-down, and only while the module is on")
    func defaultSetPlacesThePair() throws {
        let withDebug = MainWindowToolbar.defaultItems(includingDebugItems: true)
        let actions = try #require(withDebug.firstIndex(of: MainWindowToolbar.actions))

        #expect(Array(withDebug[(actions - 2)..<actions]) == MainWindowToolbar.debugDefaultItemIdentifiers)
        #expect(MainWindowToolbar.defaultItems(includingDebugItems: false) == MainWindowToolbar.defaultItemIdentifiers)
    }

    @Test("Every other tab kind and Agent mode take the debug pair out of the titlebar", arguments: [
        TabType.query, .table, .createTable, .erDiagram, .serverDashboard, .usersRoles, .insights, .tableHealth,
        .objectSource, .versionHistory, .tableListing,
    ])
    func otherKindsHideThePair(tabKind: TabType) {
        #expect(Self.hidden(tabKind: tabKind).isSuperset(of: Self.pair))
        #expect(Self.hidden(tabKind: .routineDebug, contentMode: .agent).isSuperset(of: Self.pair))
    }

    @Test("A debug tab shows its pair in place of Refresh and the commit control")
    func debugTabSwapsTheContentRun() {
        let hidden = Self.hidden(tabKind: .routineDebug)

        #expect(hidden.isDisjoint(with: Self.pair))
        #expect(hidden.contains(MainWindowToolbar.refresh))
        #expect(hidden.contains(MainWindowToolbar.saveChanges))
    }

    @Test("A debug tab stays within the titlebar's eight hit targets")
    func debugTabKeepsTheCeiling() {
        let hidden = Self.hidden(tabKind: .routineDebug)
        let targets: [NSToolbarItem.Identifier] = [
            .toggleSidebar, MainWindowToolbar.connection, MainWindowToolbar.database, MainWindowToolbar.refresh,
            MainWindowToolbar.saveChanges, MainWindowToolbar.actions, MainWindowToolbar.safeMode, MainWindowToolbar.inspector,
        ] + MainWindowToolbar.debugDefaultItemIdentifiers

        #expect(targets.filter { !hidden.contains($0) }.count <= 8)
    }

    @Test("With the module off nothing of the debugger is hidden, because nothing of it is there")
    func moduleOffHidesNothingDebug() {
        let hidden = Self.hidden(tabKind: .table, showsDebugItems: false)

        #expect(hidden.isDisjoint(with: MainWindowToolbar.debugItemIdentifiers))
        #expect(ToolbarContextResolver.hideableItems(showsDebugItems: false) == ToolbarContextResolver.hideableIdentifiers)
    }

    @Test("Each debug control answers from what the selected run can do")
    func controlsFollowTheRun() {
        let context = ToolbarContext(
            tabKind: .routineDebug,
            pane: .content,
            isConnected: true,
            hasSelectedWorkspace: true,
            showsDebugItems: true,
            debugCommands: [.stepOver],
            canStopDebugging: true
        )

        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.debugStepOver, context: context))
        #expect(!ToolbarContextResolver.isEnabled(MainWindowToolbar.debugContinue, context: context))
        #expect(!ToolbarContextResolver.isEnabled(MainWindowToolbar.debugStepOut, context: context))
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.debugStop, context: context))
        #expect(!ToolbarContextResolver.isEnabled(MainWindowToolbar.debugStop, context: ToolbarContext(tabKind: .table)))
    }

    // A restored arrangement: the app's own items, without spaces, on a private identifier that never autosaves.
    private static func restoredToolbar(
        including extra: [NSToolbarItem.Identifier] = [],
        moduleOn: Bool,
        record: ToolbarDebugItemsRecord
    ) -> (owner: MainWindowToolbar, toolbar: NSToolbar) {
        let toolbar = NSToolbar(identifier: "com.TablePro.tests.debug.\(UUID().uuidString)")
        toolbar.autosavesConfiguration = false
        let owner = MainWindowToolbar(managedToolbar: toolbar)
        owner.debugItemsEnabled = { moduleOn }
        owner.debugItemsRecord = record
        owner.isInWindow = { true }
        let placed = [
            MainWindowToolbar.connection, MainWindowToolbar.database, MainWindowToolbar.refresh,
            MainWindowToolbar.saveChanges,
        ] + extra + [MainWindowToolbar.actions, MainWindowToolbar.safeMode]
        for (index, identifier) in placed.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
        return (owner, toolbar)
    }

    @Test("The first window after launch with the module on gains Continue and Stop in a customized arrangement, once")
    func attachAfterModuleOnGainsThePair() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarDebugItemsRecord(defaults: storage.defaults)
        #expect(!record.isApplied)
        let (owner, toolbar) = Self.restoredToolbar(moduleOn: true, record: record)

        owner.reconcileDebugItems()

        let identifiers = toolbar.items.map { $0.itemIdentifier }
        let actions = identifiers.firstIndex(of: MainWindowToolbar.actions) ?? 0
        #expect(actions >= 2)
        #expect(Array(identifiers[max(0, actions - 2)..<actions]) == MainWindowToolbar.debugDefaultItemIdentifiers)
        #expect(ToolbarDebugItemsRecord(defaults: storage.defaults).isApplied)

        let (laterOwner, laterToolbar) = Self.restoredToolbar(moduleOn: true, record: record)
        laterOwner.reconcileDebugItems()
        #expect(!laterToolbar.items.contains { MainWindowToolbar.debugItemIdentifiers.contains($0.itemIdentifier) })
    }

    @Test("With the module off, a saved arrangement holding the debug controls shows none of them")
    func moduleOffHidesSavedPair() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarDebugItemsRecord(defaults: storage.defaults)
        record.record(true)
        let (owner, toolbar) = Self.restoredToolbar(
            including: MainWindowToolbar.debugDefaultItemIdentifiers,
            moduleOn: false,
            record: record
        )

        owner.reconcileDebugItems()

        #expect(!toolbar.items.contains { MainWindowToolbar.debugItemIdentifiers.contains($0.itemIdentifier) })
        #expect(!record.isApplied)
    }

    @Test("Step controls added from the palette leave the titlebar off a debug tab and in Agent mode")
    func paletteStepsHideOffDebugTabs() {
        let steps: Set<NSToolbarItem.Identifier> = [
            MainWindowToolbar.debugStepOver, MainWindowToolbar.debugStepInto, MainWindowToolbar.debugStepOut,
        ]

        #expect(Self.hidden(tabKind: .table).isSuperset(of: steps))
        #expect(Self.hidden(tabKind: .routineDebug, contentMode: .agent).isSuperset(of: steps))
        #expect(Self.hidden(tabKind: .routineDebug).isDisjoint(with: steps))
        #expect(Self.hidden(tabKind: .table, showsDebugItems: false).isDisjoint(with: steps))
    }

    @Test("The delegate vends the debug controls only while the module is on, fresh each time")
    func delegateGatesOnTheModule() {
        let owner = MainWindowToolbar()
        owner.debugItemsEnabled = { false }
        for identifier in MainWindowToolbar.debugItemIdentifiers {
            #expect(owner.toolbar(owner.managedToolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true) == nil)
        }
        #expect(owner.toolbarAllowedItemIdentifiers(owner.managedToolbar) == MainWindowToolbar.allowedItemIdentifiers)

        owner.debugItemsEnabled = { true }
        for identifier in MainWindowToolbar.debugItemIdentifiers {
            let first = owner.toolbar(owner.managedToolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true)
            let second = owner.toolbar(owner.managedToolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: false)
            #expect(first != nil && second != nil && first !== second, "\(identifier.rawValue)")
        }
        let allowed = Set(owner.toolbarAllowedItemIdentifiers(owner.managedToolbar))
        #expect(allowed.isSuperset(of: owner.toolbarDefaultItemIdentifiers(owner.managedToolbar)))
        #expect(allowed.isSuperset(of: MainWindowToolbar.debugItemIdentifiers))
    }
}
