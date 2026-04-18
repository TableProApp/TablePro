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
//  so existing subviews (ConnectionStatusView, SafeModeBadgeView, popovers,
//  etc.) are reused verbatim.
//

import AppKit
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
    private var hostingControllers: [NSToolbarItem.Identifier: NSHostingController<AnyView>] = [:]

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
        self.managedToolbar.allowsUserCustomization = false
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
        hostingControllers.removeAll()
        coordinator = nil
    }

    // MARK: - Identifiers

    private static let connection = NSToolbarItem.Identifier("com.TablePro.toolbar.connection")
    private static let database = NSToolbarItem.Identifier("com.TablePro.toolbar.database")
    private static let refresh = NSToolbarItem.Identifier("com.TablePro.toolbar.refresh")
    private static let saveChanges = NSToolbarItem.Identifier("com.TablePro.toolbar.saveChanges")
    private static let principal = NSToolbarItem.Identifier("com.TablePro.toolbar.principal")
    private static let quickSwitcher = NSToolbarItem.Identifier("com.TablePro.toolbar.quickSwitcher")
    private static let newTab = NSToolbarItem.Identifier("com.TablePro.toolbar.newTab")
    private static let filters = NSToolbarItem.Identifier("com.TablePro.toolbar.filters")
    private static let previewSQL = NSToolbarItem.Identifier("com.TablePro.toolbar.previewSQL")
    private static let results = NSToolbarItem.Identifier("com.TablePro.toolbar.results")
    private static let inspector = NSToolbarItem.Identifier("com.TablePro.toolbar.inspector")
    private static let dashboard = NSToolbarItem.Identifier("com.TablePro.toolbar.dashboard")
    private static let history = NSToolbarItem.Identifier("com.TablePro.toolbar.history")
    private static let exportTables = NSToolbarItem.Identifier("com.TablePro.toolbar.export")
    private static let importTables = NSToolbarItem.Identifier("com.TablePro.toolbar.import")
    private static let refreshSaveGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.refreshSaveGroup")
    private static let exportImportGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.exportImportGroup")

    // MARK: - NSToolbarDelegate

    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Layout: [sidebar][sidebar sep] [left actions] [flex] [Principal]
        //         [flex] [right actions] [Inspector]
        //
        // No `inspectorTrackingSeparator`: with NSHostingView setup (no
        // NSSplitViewItem with `.inspector` behavior), the separator creates
        // a separate trailing region that ABSORBS flex space, leaving right
        // items pinned next to the principal instead of at the right edge.
        // Plain `[flex, principal, flex, …rightItems, inspector]` justifies
        // right items against the inspector toggle (Apple Music-style).
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            Self.connection,
            Self.database,
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
        case Self.connection:
            return hostingItem(id: itemIdentifier, label: String(localized: "Connection"),
                               content: ConnectionToolbarButton(coordinator: coordinator))
        case Self.database:
            return hostingItem(id: itemIdentifier, label: String(localized: "Database"),
                               content: DatabaseToolbarButton(coordinator: coordinator))
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
            return hostingItem(id: itemIdentifier, label: String(localized: "Inspector"),
                               content: InspectorToolbarButton(coordinator: coordinator))
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

    private func hostingItem<Content: View>(
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
    @State private var showSwitcher = false

    var body: some View {
        Button {
            showSwitcher.toggle()
        } label: {
            Label("Connection", systemImage: "network")
        }
        .help(String(localized: "Switch Connection (⌘⌥C)"))
        .popover(isPresented: $showSwitcher) {
            ConnectionSwitcherPopover {
                showSwitcher = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConnectionSwitcher)) { _ in
            showSwitcher = true
        }
    }
}

private struct DatabaseToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        let supportsSwitch = PluginManager.shared.supportsDatabaseSwitching(for: state.databaseType)
        Button {
            coordinator.commandActions?.openDatabaseSwitcher()
        } label: {
            Label("Database", systemImage: "cylinder")
        }
        .help(String(localized: "Open Database (⌘K)"))
        .disabled(
            !supportsSwitch
                || state.connectionState != .connected
                || PluginManager.shared.connectionMode(for: state.databaseType) == .fileBased
        )
        .opacity(supportsSwitch ? 1 : 0)
        .allowsHitTesting(supportsSwitch)
    }
}

private struct RefreshToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        Button {
            NotificationCenter.default.post(name: .refreshData, object: nil)
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
            coordinator.commandActions?.newTab()
            // Defensive: a new window will become key. Restore its first
            // responder so AppKit's responder chain — which SwiftUI uses to
            // resolve `@FocusedValue` — points back at MainContentView.
            // Belt-and-suspenders for the `.focusable(false)` fix in
            // `hostingItem`; covers any path where SwiftUI might still
            // briefly retain scene focus on the toolbar's hosting controller.
            DispatchQueue.main.async {
                if let key = NSApp.keyWindow {
                    key.makeFirstResponder(key.contentView)
                }
            }
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
        .opacity(state.isTableTab ? 0 : 1)
        .allowsHitTesting(!state.isTableTab)
    }
}

private struct InspectorToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        Button {
            coordinator.commandActions?.toggleRightSidebar()
        } label: {
            Label("Inspector", systemImage: "sidebar.trailing")
        }
        .help(String(localized: "Toggle Inspector (⌘⌥I)"))
        .disabled(state.connectionState != .connected)
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
        let supportsImport = PluginManager.shared.supportsImport(for: state.databaseType)
        Button {
            coordinator.commandActions?.importTables()
        } label: {
            Label("Import", systemImage: "square.and.arrow.down")
        }
        .help(String(localized: "Import Data (⌘⇧I)"))
        .disabled(
            state.connectionState != .connected
                || state.safeModeLevel.blocksAllWrites
                || !supportsImport
        )
        .opacity(supportsImport ? 1 : 0)
        .allowsHitTesting(supportsImport)
    }
}
