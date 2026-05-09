//
//  MainWindowToolbar.swift
//  TablePro
//
//  NSToolbar + NSToolbarDelegate for the main editor window. Replaces the
//  SwiftUI `.toolbar { ... }` modifier (`TableProToolbarView.openTableToolbar`)
//  which only produces a visible toolbar inside a SwiftUI WindowGroup scene.
//  Under AppKit-imperative window management (TabWindowController hosting
//  ContentView via NSHostingView), SwiftUI has no scene to attach its toolbar
//  items to — NSToolbar must be constructed directly on NSWindow.
//
//  Each item's content is still authored in SwiftUI (`NSHostingView(rootView:)`)
//  so existing subviews (ConnectionStatusView, SafeModeBadgeView, popovers,x
//  etc.) are reused verbatim.
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit

@MainActor
internal final class MainWindowToolbar: NSObject, NSToolbarDelegate {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    /// The coordinator whose toolbar state drives every item. Held weak so a
    /// closed window's delegate doesn't retain a torn-down coordinator.
    private weak var coordinator: MainContentCoordinator?

    /// The NSToolbar this delegate manages. Exposed so the controller can
    /// verify `window.toolbar === managedToolbar` after install — macOS may
    /// silently discard an assignment made during tab-group merge.
    internal let managedToolbar: NSToolbar

    /// Retain the hosting controllers — without this, NSHostingController
    /// deallocs immediately and its view becomes orphaned, producing zero-size
    /// items that get pushed right by flexibleSpace.
    internal var hostingControllers: [NSToolbarItem.Identifier: NSHostingController<AnyView>] = [:]
    private var sidebarButtons: [NSButton] = []
    private var sidebarObservationTask: Task<Void, Never>?
    private var splitViewObserver: NSObjectProtocol?

    internal init(coordinator: MainContentCoordinator) {
        self.coordinator = coordinator
        // Unique identifier per toolbar instance. With a shared identifier
        // across tab-group members, macOS collapses them into one toolbar and
        // only the first window's items render — subsequent tabs show an
        // empty toolbar.
        self.managedToolbar = NSToolbar(identifier: "com.TablePro.main.toolbar.\(UUID().uuidString)")
        super.init()
        self.managedToolbar.delegate = self
        self.managedToolbar.displayMode = .iconOnly
        self.managedToolbar.allowsUserCustomization = true
        self.managedToolbar.autosavesConfiguration = false
        // Per WWDC 2023 / Apple Music pattern: do NOT use
        // `centeredItemIdentifiers` together with a right cluster that should
        // justify against `inspectorTrackingSeparator`. The centered API
        // anchors the principal to region center and collapses any trailing
        // flex to zero — so right items end up packed just right of the
        // principal instead of at the inspector edge. With plain
        // `[flex, principal, flex, …rightItems, inspectorSep, inspector]`
        // and NO centered identifier, the two flexes balance naturally:
        // principal floats to center, right items pack against the
        // inspectorTrackingSeparator (right edge).

    }

    /// Release all hosted toolbar views and sever the coordinator reference.
    /// Called by TabWindowController.windowWillClose before coordinator teardown.
    func invalidate() {
        sidebarObservationTask?.cancel()
        sidebarObservationTask = nil
        if let observer = splitViewObserver {
            NotificationCenter.default.removeObserver(observer)
            splitViewObserver = nil
        }
        sidebarButtons = []
        hostingControllers.removeAll()
        coordinator = nil
    }

    // MARK: - Identifiers

    private static let connectionGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.connectionGroup")
    private static let refresh = NSToolbarItem.Identifier("com.TablePro.toolbar.refresh")
    private static let saveChanges = NSToolbarItem.Identifier("com.TablePro.toolbar.saveChanges")
    private static let principal = NSToolbarItem.Identifier("com.TablePro.toolbar.principal")
    private static let quickSwitcher = NSToolbarItem.Identifier("com.TablePro.toolbar.quickSwitcher")
    private static let newTab = NSToolbarItem.Identifier("com.TablePro.toolbar.newTab")
    private static let filters = NSToolbarItem.Identifier("com.TablePro.toolbar.filters")
    private static let previewSQL = NSToolbarItem.Identifier("com.TablePro.toolbar.previewSQL")
    private static let results = NSToolbarItem.Identifier("com.TablePro.toolbar.results")
    private static let inspector = NSToolbarItem.Identifier.toggleInspector
    private static let dashboard = NSToolbarItem.Identifier("com.TablePro.toolbar.dashboard")
    private static let history = NSToolbarItem.Identifier("com.TablePro.toolbar.history")
    private static let exportTables = NSToolbarItem.Identifier("com.TablePro.toolbar.export")
    private static let importTables = NSToolbarItem.Identifier("com.TablePro.toolbar.import")
    private static let refreshSaveGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.refreshSaveGroup")
    private static let exportImportGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.exportImportGroup")
    private static let sidebarToggle = NSToolbarItem.Identifier("com.TablePro.toolbar.sidebarToggle")

    // MARK: - NSToolbarDelegate

    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.sidebarToggle,
            .sidebarTrackingSeparator,
            Self.connectionGroup,
            Self.refreshSaveGroup,
            .flexibleSpace,
            Self.principal,
            .flexibleSpace,
            Self.quickSwitcher,
            Self.newTab,
            Self.filters,
            Self.previewSQL,
            Self.inspector,
        ]
    }

    internal func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Default + secondary actions hidden by default. Available via menus
        // and keyboard shortcuts:
        // - Results toggle (Cmd+Opt+R) — contextual to query tabs only
        //   (invisible on table tabs, disabled with no tabs); auto-expands
        //   when a query produces new results, so the manual toggle is
        //   rarely needed.
        // - Export/Import (File menu, Cmd+Shift+E/I)
        // - Dashboard/History (View menu, Cmd+Y for history)
        toolbarDefaultItemIdentifiers(toolbar) + [
            Self.results,
            Self.exportImportGroup,
            Self.dashboard,
            Self.history,
        ]
    }

    internal func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        Self.lifecycleLogger.info(
            "[open] toolbar delegate buildItem id=\(itemIdentifier.rawValue, privacy: .public) hasCoordinator=\(self.coordinator != nil)"
        )
        guard let coordinator else { return nil }

        switch itemIdentifier {
        case Self.sidebarToggle:
            return makeSidebarToggleItem(coordinator: coordinator)
        case Self.connectionGroup:
            return hostingItem(id: itemIdentifier, label: String(localized: "Connection"),
                               content: HStack(spacing: 4) {
                                   ConnectionToolbarButton(coordinator: coordinator)
                                   DatabaseToolbarButton(coordinator: coordinator)
                               })
        case Self.refresh:
            return hostingItem(id: itemIdentifier, label: String(localized: "Refresh"),
                               content: RefreshToolbarButton(coordinator: coordinator))
        case Self.saveChanges:
            return hostingItem(id: itemIdentifier, label: String(localized: "Save Changes"),
                               content: SaveChangesToolbarButton(coordinator: coordinator))
        case Self.principal:
            return hostingItem(id: itemIdentifier, label: "",
                               content: ToolbarPrincipalContent(
                                   state: coordinator.toolbarState,
                                   onSwitchDatabase: { [weak coordinator] in coordinator?.commandActions?.openDatabaseSwitcher() },
                                   onCancelQuery: { [weak coordinator] in coordinator?.cancelCurrentQuery() }
                               ))
        case Self.quickSwitcher:
            return hostingItem(id: itemIdentifier, label: String(localized: "Quick Switcher"),
                               content: QuickSwitcherToolbarButton(coordinator: coordinator))
        case Self.newTab:
            return hostingItem(id: itemIdentifier, label: String(localized: "New Tab"),
                               content: NewTabToolbarButton(coordinator: coordinator))
        case Self.filters:
            return hostingItem(id: itemIdentifier, label: String(localized: "Filters"),
                               content: FiltersToolbarButton(coordinator: coordinator))
        case Self.previewSQL:
            return hostingItem(id: itemIdentifier, label: String(localized: "Preview"),
                               content: PreviewSQLToolbarButton(coordinator: coordinator))
        case Self.results:
            return hostingItem(id: itemIdentifier, label: String(localized: "Results"),
                               content: ResultsToolbarButton(coordinator: coordinator))
        case Self.inspector:
            let item = NSToolbarItem(itemIdentifier: Self.inspector)
            item.label = String(localized: "Inspector")
            item.paletteLabel = String(localized: "Inspector")
            return item
        case Self.dashboard:
            return hostingItem(id: itemIdentifier, label: String(localized: "Dashboard"),
                               content: DashboardToolbarButton(coordinator: coordinator))
        case Self.history:
            return hostingItem(id: itemIdentifier, label: String(localized: "History"),
                               content: HistoryToolbarButton(coordinator: coordinator))
        case Self.exportTables:
            return hostingItem(id: itemIdentifier, label: String(localized: "Export"),
                               content: ExportToolbarButton(coordinator: coordinator))
        case Self.importTables:
            return hostingItem(id: itemIdentifier, label: String(localized: "Import"),
                               content: ImportToolbarButton(coordinator: coordinator))
        case Self.refreshSaveGroup:
            return hostingItem(id: itemIdentifier, label: String(localized: "Refresh & Save"),
                               content: HStack(spacing: 4) {
                                   RefreshToolbarButton(coordinator: coordinator)
                                   SaveChangesToolbarButton(coordinator: coordinator)
                               })
        case Self.exportImportGroup:
            return hostingItem(id: itemIdentifier, label: String(localized: "Export & Import"),
                               content: HStack(spacing: 4) {
                                   ExportToolbarButton(coordinator: coordinator)
                                   ImportToolbarButton(coordinator: coordinator)
                               })
        default:
            return nil
        }
    }

    // MARK: - Helpers

    internal func hostingItem<Content: View>(
        id: NSToolbarItem.Identifier,
        label: String,
        content: Content
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        // NSHostingController drives its view's `intrinsicContentSize` from the
        // SwiftUI body (via `sizingOptions = .intrinsicContentSize`). A bare
        // `NSHostingView` returns intrinsicContentSize = 0 for not-yet-rendered
        // SwiftUI content, causing NSToolbar to collapse the item to width 0 —
        // the symptom was "items all jammed to the right edge by flexibleSpace".
        //
        // The controller MUST be retained by us (kept in `hostingControllers`);
        // otherwise it deallocs immediately and its hosted view becomes orphaned.
        //
        // `.focusable(false)` keeps SwiftUI from claiming "scene focus" inside
        // this NSHostingController when its Button is clicked. Without it,
        // each toolbar button click made @FocusedValue(\.commandActions)
        // resolve from the toolbar's empty SwiftUI scene → menu shortcuts
        // (Cmd+1...9, Cmd+R, etc.) became disabled until the user clicked
        // back into the editor.
        let controller = NSHostingController(rootView: AnyView(content.focusable(false)))
        controller.sizingOptions = .intrinsicContentSize
        hostingControllers[id] = controller
        item.view = controller.view
        return item
    }
}

// MARK: - Item SwiftUI Views
//
// Each view reads state from `coordinator.toolbarState` (@Observable → automatic
// re-render) and invokes actions via `coordinator.commandActions` (set by
// MainContentView.onAppear). SQLReviewPopover + ConnectionSwitcherPopover are
// re-used verbatim from the SwiftUI toolbar.

private struct ConnectionToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        @Bindable var state = coordinator.toolbarState
        Button {
            state.showConnectionSwitcher.toggle()
        } label: {
            Label("Connection", systemImage: "network")
        }
        .help(String(localized: "Switch Connection (⌘⌥C)"))
        .popover(isPresented: $state.showConnectionSwitcher) {
            ConnectionSwitcherPopover {
                state.showConnectionSwitcher = false
            }
        }
    }
}

private struct DatabaseToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        let supportsSwitch = PluginManager.shared.supportsDatabaseSwitching(for: state.databaseType)
        if supportsSwitch {
            Button {
                coordinator.commandActions?.openDatabaseSwitcher()
            } label: {
                Label("Database", systemImage: "cylinder")
            }
            .help(String(localized: "Open Database (⌘K)"))
            .disabled(
                state.connectionState != .connected
                    || PluginManager.shared.connectionMode(for: state.databaseType) == .fileBased
            )
        }
    }
}

private struct RefreshToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        Button {
            AppCommands.shared.refreshData.send(nil)
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help(String(localized: "Refresh (⌘R)"))
        .disabled(state.connectionState != .connected)
    }
}

private struct SaveChangesToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        Button {
            coordinator.commandActions?.saveChanges()
        } label: {
            Label("Save Changes", systemImage: "checkmark.circle.fill")
        }
        .help(String(localized: "Save Changes (⌘S)"))
        // Match menu: also disable when read-only (safe mode blocks writes).
        .disabled(
            !state.hasPendingChanges
                || state.connectionState != .connected
                || state.safeModeLevel.blocksAllWrites
        )
        .tint(.accentColor)
    }
}

private struct QuickSwitcherToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        Button {
            coordinator.commandActions?.openQuickSwitcher()
        } label: {
            Label("Quick Switcher", systemImage: "magnifyingglass")
        }
        .help(String(localized: "Quick Switcher (⇧⌘O)"))
        .disabled(state.connectionState != .connected)
    }
}

private struct NewTabToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        Button {
            NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
        } label: {
            Label("New Tab", systemImage: "plus.rectangle")
        }
        .help(String(localized: "New Query Tab (⌘T)"))
        .disabled(state.connectionState != .connected)
    }
}

private struct FiltersToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        Button {
            coordinator.commandActions?.toggleFilterPanel()
        } label: {
            Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help(String(localized: "Toggle Filters (⇧⌘F)"))
        .disabled(state.connectionState != .connected || !state.isTableTab)
    }
}

private struct PreviewSQLToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        @Bindable var state = coordinator.toolbarState
        Button {
            coordinator.commandActions?.previewSQL()
        } label: {
            let langName = PluginManager.shared.queryLanguageName(for: state.databaseType)
            Label(String(format: String(localized: "Preview %@"), langName), systemImage: "eye")
        }
        .help(String(format: String(localized: "Preview %@ (⌘⇧P)"), PluginManager.shared.queryLanguageName(for: state.databaseType)))
        .disabled(!state.hasDataPendingChanges || state.connectionState != .connected)
        .popover(isPresented: $state.showSQLReviewPopover) {
            SQLReviewPopover(statements: state.previewStatements, databaseType: state.databaseType)
        }
    }
}

private struct ResultsToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        if !state.isTableTab {
            Button {
                coordinator.commandActions?.toggleResults()
            } label: {
                Label(
                    "Results",
                    systemImage: state.isResultsCollapsed
                        ? "rectangle.bottomhalf.inset.filled"
                        : "rectangle.inset.filled"
                )
            }
            .help(String(localized: "Toggle Results (⌘⌥R)"))
            .disabled(state.connectionState != .connected)
        }
    }
}

private struct DashboardToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        let supportsDashboard = coordinator.commandActions?.supportsServerDashboard ?? false
        Button {
            coordinator.commandActions?.showServerDashboard()
        } label: {
            Label(String(localized: "Dashboard"), systemImage: "gauge.with.dots.needle.33percent")
        }
        .help(String(localized: "Server Dashboard"))
        .disabled(state.connectionState != .connected || !supportsDashboard)
    }
}

private struct HistoryToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        Button {
            coordinator.commandActions?.toggleHistoryPanel()
        } label: {
            Label("History", systemImage: "clock")
        }
        .help(String(localized: "Toggle Query History (⌘Y)"))
    }
}

private struct ExportToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        Button {
            coordinator.commandActions?.exportTables()
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help(String(localized: "Export Data (⌘⇧E)"))
        .disabled(state.connectionState != .connected)
    }
}

private struct ImportToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        if PluginManager.shared.supportsImport(for: state.databaseType) {
            Button {
                coordinator.commandActions?.importTables()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help(String(localized: "Import Data (⌘⇧I)"))
            .disabled(
                state.connectionState != .connected
                    || state.safeModeLevel.blocksAllWrites
            )
        }
    }
}

// MARK: - Sidebar Toggle (Pure AppKit)

extension MainWindowToolbar {
    fileprivate func makeSidebarToggleItem(coordinator: MainContentCoordinator) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.sidebarToggle)
        item.label = String(localized: "Sidebar")
        item.paletteLabel = String(localized: "Sidebar")

        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 2

        let tablesButton = makeSidebarNSButton(
            icon: "list.bullet",
            label: String(localized: "Tables"),
            tag: 0
        )
        let favoritesButton = makeSidebarNSButton(
            icon: "star",
            label: String(localized: "Favorites"),
            tag: 1
        )

        container.addArrangedSubview(tablesButton)
        container.addArrangedSubview(favoritesButton)

        sidebarButtons = [tablesButton, favoritesButton]
        item.view = container

        syncSidebarButtonState(coordinator: coordinator)
        startSidebarObservation(coordinator: coordinator)

        return item
    }

    private func makeSidebarNSButton(icon: String, label: String, tag: Int) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .recessed
        button.setButtonType(.momentaryPushIn)
        button.showsBorderOnlyWhileMouseInside = true
        button.isBordered = true
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.tag = tag
        button.target = self
        button.action = #selector(sidebarButtonClicked(_:))
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }

    @objc fileprivate func sidebarButtonClicked(_ sender: NSButton) {
        guard let coordinator else { return }
        let tabs: [SidebarTab] = [.tables, .favorites]
        guard sender.tag >= 0, sender.tag < tabs.count else { return }
        coordinator.splitViewController?.setSidebarTab(tabs[sender.tag])
    }

    fileprivate func syncSidebarButtonState(coordinator: MainContentCoordinator) {
        guard sidebarButtons.count == 2 else { return }
        let state = coordinator.toolbarState
        let sidebarState = SharedSidebarState.forConnection(coordinator.connectionId)
        let isConnected = state.connectionState == .connected || state.connectionState == .executing
        let sidebarVisible = !(coordinator.splitViewController?.isSidebarCollapsed ?? true)
        let icons = ["list.bullet", "star"]
        let activeIcons = ["list.bullet", "star.fill"]

        for (index, button) in sidebarButtons.enumerated() {
            let isActive = sidebarVisible && isConnected
                && (index == 0 ? sidebarState.selectedSidebarTab == .tables : sidebarState.selectedSidebarTab == .favorites)
            button.isEnabled = isConnected
            button.showsBorderOnlyWhileMouseInside = !isActive
            let icon = isActive ? activeIcons[index] : icons[index]
            button.image = NSImage(systemSymbolName: icon, accessibilityDescription: button.accessibilityLabel())
        }
    }

    fileprivate func startSidebarObservation(coordinator: MainContentCoordinator) {
        sidebarObservationTask?.cancel()

        // Observe @Observable state changes (selected tab, connection state)
        sidebarObservationTask = Task { [weak self, weak coordinator] in
            guard let coordinator else { return }
            while !Task.isCancelled {
                let sidebarState = SharedSidebarState.forConnection(coordinator.connectionId)
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = coordinator.toolbarState.connectionState
                        _ = sidebarState.selectedSidebarTab
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    self.syncSidebarButtonState(coordinator: coordinator)
                }
            }
        }

        // Observe NSSplitView resize to catch sidebar collapse/expand from
        // keyboard shortcut, drag, or any non-button path.
        splitViewObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: coordinator.splitViewController?.splitView,
            queue: .main
        ) { [weak self, weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let self, let coordinator else { return }
                self.syncSidebarButtonState(coordinator: coordinator)
            }
        }
    }
}
