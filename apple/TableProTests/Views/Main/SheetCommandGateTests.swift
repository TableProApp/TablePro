//
//  SheetCommandGateTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

// A stubbed sheet, so the case puts nothing on screen.
private final class SheetHostWindow: NSWindow {
    var stubbedSheet: NSWindow?
    override var attachedSheet: NSWindow? { stubbedSheet }
}

@MainActor
struct SheetCommandGateTests {
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func makeHostWindow(withSheet: Bool) -> SheetHostWindow {
        let window = SheetHostWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.stubbedSheet = withSheet ? makeWindow() : nil
        return window
    }

    private static func makeActions(for fixture: CoordinatorFixture) -> MainContentCommandActions {
        MainContentCommandActions(
            coordinator: fixture.coordinator,
            connection: fixture.connection,
            selectedTables: .constant([]),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            trailingPaneState: TrailingPaneState()
        )
    }

    // Every surface below lights these commands, so only the sheet decides.
    private static func menuContext(isPresentingSheet: Bool) -> MenuValidationContext {
        var context = MenuValidationContext()
        context.hasSelectedWorkspace = true
        context.isConnected = true
        context.hasPendingChanges = true
        context.hasDataPendingChanges = true
        context.hasImportFormats = true
        context.canRestorePreviousValues = true
        context.hasQueryText = true
        context.canDisconnect = true
        context.isPresentingSheet = isPresentingSheet
        return context
    }

    private static func toolbarContext(isPresentingSheet: Bool) -> ToolbarContext {
        ToolbarContext(
            tabKind: .table,
            pane: .content,
            isConnected: true,
            hasSelectedWorkspace: true,
            pendingChange: .data,
            hasDataPendingChanges: true,
            canRestorePreviousValues: true,
            supportsImport: true,
            isPresentingSheet: isPresentingSheet
        )
    }

    private static let menuAndToolbarTwins: [(selector: Selector, item: NSToolbarItem.Identifier)] = [
        (#selector(MainSplitViewController.saveDocument(_:)), MainWindowToolbar.saveChanges),
        (#selector(MainSplitViewController.previewSQL(_:)), MainWindowToolbar.previewSQL),
        (#selector(MainSplitViewController.exportTables(_:)), MainWindowToolbar.exportTables),
        (#selector(MainSplitViewController.importData(_:)), MainWindowToolbar.importTables),
        (#selector(MainSplitViewController.restorePreviousValues(_:)), MainWindowToolbar.restorePreviousValues),
    ]

    // MARK: - The predicate

    @Test("A sheet the coordinator named counts before SwiftUI attaches it")
    func namedSheetCounts() {
        let fixture = CoordinatorFixture()
        #expect(!fixture.coordinator.isPresentingSheet)

        fixture.coordinator.activeSheet = .exportDialog
        #expect(fixture.coordinator.isPresentingSheet)

        fixture.coordinator.activeSheet = nil
        #expect(!fixture.coordinator.isPresentingSheet)
    }

    @Test("A sheet any presenter attached to the window counts, with no sheet named")
    func attachedSheetCounts() {
        let fixture = CoordinatorFixture()
        let window = Self.makeHostWindow(withSheet: true)
        fixture.coordinator.contentWindow = window
        #expect(fixture.coordinator.activeSheet == nil)
        #expect(fixture.coordinator.isPresentingSheet)
        #expect(!fixture.coordinator.admitsSheetCommand())

        window.stubbedSheet = nil
        #expect(!fixture.coordinator.isPresentingSheet)
        #expect(fixture.coordinator.admitsSheetCommand())
    }

    @Test("A pending favorite sheet blocks export before AppKit attaches it")
    func favoriteSheetCounts() {
        let fixture = CoordinatorFixture()
        let actions = Self.makeActions(for: fixture)
        fixture.coordinator.favoriteDialogQuery = FavoriteDialogQuery(query: "SELECT 1")

        #expect(fixture.coordinator.isPresentingSheet)
        actions.exportTables()
        #expect(fixture.coordinator.activeSheet == nil)

        fixture.coordinator.favoriteDialogQuery = nil
        #expect(!fixture.coordinator.isPresentingSheet)
    }

    @Test("A pending file conflict sheet blocks export before AppKit attaches it")
    func fileConflictSheetCounts() {
        let fixture = CoordinatorFixture()
        let actions = Self.makeActions(for: fixture)
        fixture.coordinator.fileConflictRequest = MainContentCoordinator.FileConflictRequest(
            tabId: UUID(), url: URL(fileURLWithPath: "/query.sql"), mineContent: "SELECT 1", diskContent: "SELECT 2"
        )

        #expect(fixture.coordinator.isPresentingSheet)
        actions.exportTables()
        #expect(fixture.coordinator.activeSheet == nil)

        fixture.coordinator.fileConflictRequest = nil
        #expect(!fixture.coordinator.isPresentingSheet)
    }

    @Test("Restore Previous Values reached without validation keeps the export sheet")
    func restoreRefusesOverExport() {
        let fixture = CoordinatorFixture()
        let actions = Self.makeActions(for: fixture)
        fixture.coordinator.activeSheet = .exportDialog

        actions.restorePreviousValues()
        fixture.coordinator.rewindLastSave()
        fixture.coordinator.rewindSave(historyId: UUID())

        #expect(fixture.coordinator.activeSheet?.id == ActiveSheet.exportDialog.id)
        #expect(fixture.coordinator.rewindPlan == nil)
    }

    // MARK: - Menu bar

    @Test("Restore Previous Values dims while the window has a sheet and lights without one")
    func restorePreviousValuesMenuItem() {
        let selector = #selector(MainSplitViewController.restorePreviousValues(_:))
        #expect(MainSplitViewController.isEnabled(selector, context: Self.menuContext(isPresentingSheet: false)))
        #expect(!MainSplitViewController.isEnabled(selector, context: Self.menuContext(isPresentingSheet: true)))
    }

    @Test("Export Tables dims while the window has a sheet and lights without one")
    func exportMenuItem() {
        let selector = #selector(MainSplitViewController.exportTables(_:))
        #expect(MainSplitViewController.isEnabled(selector, context: Self.menuContext(isPresentingSheet: false)))
        #expect(!MainSplitViewController.isEnabled(selector, context: Self.menuContext(isPresentingSheet: true)))
    }

    @Test("Disconnect dims under a sheet in Browse and Agent mode")
    func disconnectMenuItem() {
        let selector = #selector(MainSplitViewController.requestDisconnect)
        for agentMode in [false, true] {
            var context = Self.menuContext(isPresentingSheet: false)
            context.isAgentMode = agentMode
            #expect(MainSplitViewController.isEnabled(selector, context: context))
            context.isPresentingSheet = true
            #expect(!MainSplitViewController.isEnabled(selector, context: context))
        }
    }

    @Test("Every sheet command is one the window validates, so a sheet dims each of them")
    func everySheetCommandDims() {
        let context = Self.menuContext(isPresentingSheet: true)
        for selector in MainSplitViewController.sheetCommandSelectors {
            #expect(
                MainSplitViewController.resolvedEnablement(selector, context: context) == false,
                "\(NSStringFromSelector(selector)) must dim under a sheet"
            )
        }
    }

    @Test("A command that presents no sheet keeps working under one")
    func commandsWithoutASheetStayLit() {
        let context = Self.menuContext(isPresentingSheet: true)
        let unaffected = [
            #selector(MainSplitViewController.refreshDatabase(_:)),
            #selector(MainSplitViewController.executeQuery(_:)),
            #selector(MainSplitViewController.newEditorTab(_:)),
            #selector(MainSplitViewController.openQuickSwitcher(_:)),
        ]
        for selector in unaffected {
            #expect(
                MainSplitViewController.isEnabled(selector, context: context),
                "\(NSStringFromSelector(selector)) presents no sheet and must stay lit"
            )
        }
    }

    // MARK: - Toolbar

    @Test("The toolbar's Restore Previous Values and Export dim under a sheet; Refresh does not")
    func toolbarItems() {
        let lit = Self.toolbarContext(isPresentingSheet: false)
        let covered = Self.toolbarContext(isPresentingSheet: true)
        for item in [MainWindowToolbar.restorePreviousValues, MainWindowToolbar.exportTables] {
            #expect(ToolbarContextResolver.isEnabled(item, context: lit), "\(item.rawValue) must light without a sheet")
            #expect(!ToolbarContextResolver.isEnabled(item, context: covered), "\(item.rawValue) must dim under a sheet")
        }
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.refresh, context: covered))
    }

    @Test("A toolbar item and its menu twin answer the same under a sheet")
    func menuAndToolbarAgree() {
        for twin in Self.menuAndToolbarTwins {
            for isPresentingSheet in [false, true] {
                let menu = MainSplitViewController.isEnabled(
                    twin.selector,
                    context: Self.menuContext(isPresentingSheet: isPresentingSheet)
                )
                let toolbar = ToolbarContextResolver.isEnabled(
                    twin.item,
                    context: Self.toolbarContext(isPresentingSheet: isPresentingSheet)
                )
                #expect(menu == !isPresentingSheet, "\(NSStringFromSelector(twin.selector)) answered \(menu)")
                #expect(toolbar == menu, "\(twin.item.rawValue) answered \(toolbar), its menu twin \(menu)")
            }
        }
    }

    // MARK: - The command itself

    @Test("Export reached with no validation keeps the sheet on screen instead of swapping it")
    func exportRefusesOverANamedSheet() {
        let fixture = CoordinatorFixture()
        let actions = Self.makeActions(for: fixture)

        fixture.coordinator.activeSheet = .rewind
        actions.exportTables()
        #expect(fixture.coordinator.activeSheet?.id == ActiveSheet.rewind.id)

        fixture.coordinator.activeSheet = nil
        actions.exportTables()
        #expect(fixture.coordinator.activeSheet?.id == ActiveSheet.exportDialog.id)
    }

    @Test("Export refuses over a sheet another presenter attached")
    func exportRefusesOverAnAttachedSheet() {
        let fixture = CoordinatorFixture()
        let actions = Self.makeActions(for: fixture)
        let window = Self.makeHostWindow(withSheet: true)
        fixture.coordinator.contentWindow = window

        actions.exportTables()
        #expect(fixture.coordinator.activeSheet == nil)

        window.stubbedSheet = nil
        actions.exportTables()
        #expect(fixture.coordinator.activeSheet?.id == ActiveSheet.exportDialog.id)
    }
}
