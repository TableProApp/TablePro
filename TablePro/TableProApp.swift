//
//  TableProApp.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import CodeEditTextView
import Combine
import Observation
import os
import Sparkle
import SwiftUI
import TableProPluginKit

// MARK: - Pasteboard Commands

/// Custom Commands struct for pasteboard operations
struct PasteboardCommands: Commands {
    var settingsManager: AppSettingsManager
    @FocusedValue(\.commandActions) var focusedActions: MainContentCommandActions?
    @Bindable var commandRegistry: CommandActionsRegistry

    private var actions: MainContentCommandActions? {
        focusedActions ?? commandRegistry.current
    }

    private func shortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        settingsManager.keyboard.keyboardShortcut(for: action)
    }

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .cut))

            Button("Copy") {
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) {
                    return
                }
                if actions?.hasRowSelection == true {
                    actions?.copySelectedRows()
                } else if actions?.hasTableSelection == true {
                    actions?.copyTableNames()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .copy))

            Button("Copy Rows") {
                if !NSApp.sendAction(#selector(TableProResponderActions.copyRowsAsTSV(_:)), to: nil, from: nil) {
                    actions?.copySelectedRows()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .copyRowsExplicit))
            .disabled(!(actions?.hasRowSelection ?? false))

            Button("Copy with Headers") {
                actions?.copySelectedRowsWithHeaders()
            }
            .optionalKeyboardShortcut(shortcut(for: .copyWithHeaders))
            .disabled(!(actions?.hasRowSelection ?? false))

            Button("Copy as JSON") {
                actions?.copySelectedRowsAsJson()
            }
            .optionalKeyboardShortcut(shortcut(for: .copyAsJson))
            .disabled(!(actions?.hasRowSelection ?? false))

            Button("Paste") {
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
                    return
                }
                if actions?.isCurrentTabEditable == true {
                    actions?.pasteRows()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .paste))

            Button("Delete") {
                actions?.deleteSelectedRows()
            }
            .optionalKeyboardShortcut(shortcut(for: .delete))
            .disabled(!(actions?.isCurrentTabEditable ?? false) && !(actions?.hasTableSelection ?? false))

            Divider()

            Button("Select All") {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .selectAll))

            Button("Clear Selection") {
                // Route the Esc key equivalent to Vim first when the active editor is
                // in a non-normal mode — the menu shortcut otherwise preempts the
                // local event monitor and Vim never sees the keystroke.
                if !EditorEventRouter.shared.handleVimEscapeFromMenu() {
                    NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .clearSelection))
        }
    }
}

// MARK: - App Menu Commands

/// Where `Cmd+F` resolves in the current context. The data-grid filter lives in
/// the View menu and the editor's Find lives in the Edit menu. Only the item
/// matching the current route binds `Cmd+F`; the other drops it. Two items
/// sharing one key equivalent makes SwiftUI dedupe the shortcut and AppKit bind
/// it to the disabled item, so the live owner must be unique.
enum CommandFRoute {
    case inspectorFilter
    case tableFilter
    case editorFind

    static func resolve(isInspector: Bool, isTableTab: Bool) -> CommandFRoute {
        if isInspector { return .inspectorFilter }
        if isTableTab { return .tableFilter }
        return .editorFind
    }
}

/// All menu commands extracted into a separate Commands struct so that AppState
/// changes only re-evaluate the menu items — NOT the Scene body / WindowGroups.
struct AppMenuCommands: Commands {
    var settingsManager: AppSettingsManager
    var updaterBridge: UpdaterBridge
    @FocusedValue(\.commandActions) var focusedActions: MainContentCommandActions?
    /// @Observable singleton — passed in from TableProApp via @Bindable so
    /// SwiftUI re-evaluates the menu when the current key window's actions
    /// change. Fallback for when `@FocusedValue` returns nil (e.g. after
    /// clicking a toolbar Button whose NSHostingController claims SwiftUI
    /// scene focus instead of MainContentView's).
    @Bindable var commandRegistry: CommandActionsRegistry

    /// Effective actions used by every menu item. Prefers @FocusedValue when
    /// it resolves (correct for in-content focus); falls back to the registry
    /// otherwise (covers toolbar-click + welcome→connect race scenarios).
    private var actions: MainContentCommandActions? {
        focusedActions ?? commandRegistry.current
    }

    private var sidebarLayoutBinding: Binding<SidebarLayout> {
        Binding(
            get: { actions?.sidebarLayout ?? .flat },
            set: { actions?.setSidebarLayout($0) }
        )
    }

    private func shortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        settingsManager.keyboard.keyboardShortcut(for: action)
    }

    private var openContainerMenuTitle: String {
        let containerName = actions.map {
            PluginManager.shared.containerEntityName(for: $0.currentDatabaseType)
        } ?? "Database"
        return String(format: String(localized: "Open %@..."), containerName)
    }

    /// Prefers the focused scene value; falls back to the coordinator back-reference
    /// so Cmd+W still routes through `closeTab()` (with its unsaved-changes dialog)
    /// when focus is inside an AppKit subview and `@FocusedValue` has not resolved.
    private var resolvedCloseTabActions: MainContentCommandActions? {
        if let actions { return actions }
        guard let window = NSApp.keyWindow,
              window.identifier?.rawValue.hasPrefix("main") == true
        else { return nil }
        if let coordinator = MainContentCoordinator.coordinator(forWindow: window) {
            return coordinator.commandActions
        }
        if let windowId = WindowLifecycleMonitor.shared.windowId(forWindow: window),
           let coordinator = MainContentCoordinator.coordinator(for: windowId) {
            return coordinator.commandActions
        }
        return nil
    }

    private var keyWindowIsInspector: Bool {
        NSApp.keyWindow?.windowController is InspectorWindowController
    }

    private var commandFRoute: CommandFRoute {
        CommandFRoute.resolve(isInspector: keyWindowIsInspector, isTableTab: actions?.isTableTab == true)
    }

    var body: some Commands {
        // Custom About window + Check for Updates + MCP status
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About TablePro")) {
                let linkStyle: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                let credits = NSMutableAttributedString()
                let links: [(String, String)] = [
                    ("Website", "https://tablepro.app"),
                    ("GitHub", "https://github.com/TableProApp/TablePro"),
                    (String(localized: "Documentation"), "https://docs.tablepro.app"),
                    (String(localized: "Sponsor"), "https://github.com/sponsors/datlechin")
                ]
                for (index, link) in links.enumerated() {
                    if index > 0 {
                        credits.append(NSAttributedString(string: "  |  ", attributes: linkStyle))
                    }
                    let linkAttr = NSMutableAttributedString(string: link.0, attributes: linkStyle)
                    if let url = URL(string: link.1) {
                        linkAttr.addAttribute(.link, value: url, range: NSRange(location: 0, length: linkAttr.length))
                    }
                    credits.append(linkAttr)
                }
                let centered = NSMutableParagraphStyle()
                centered.alignment = .center
                credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .credits: credits
                ])
            }
            CheckForUpdatesView(updaterBridge: updaterBridge)
            Divider()
            MCPServerMenuItem()
        }

        // MARK: - Keyboard Shortcut Architecture
        //
        // This app uses a hybrid approach for keyboard shortcuts:
        //
        // 1. **Responder Chain** (Apple Standard):
        //    - Standard actions: copy, paste, undo, delete, cancelOperation (ESC)
        //    - Context-aware: First responder handles action appropriately
        //
        // 2. **@FocusedValue** (Menu → single handler):
        //    - Most menu commands call MainContentCommandActions directly
        //    - Clean method calls, no global event bus
        //
        // 3. **NotificationCenter** (Multi-listener broadcasts only):
        //    - refreshData: targeted per-connection data-changed signal
        //    - Legitimate broadcasts where multiple views respond

        // File menu
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "New Connection...")) {
                WindowOpener.shared.openConnectionForm()
            }
            .optionalKeyboardShortcut(shortcut(for: .newConnection))

            Button("Manage Connections") {
                WindowOpener.shared.openWelcome()
            }
            .optionalKeyboardShortcut(shortcut(for: .manageConnections))

            Button(String(localized: "Open Sample Database")) {
                SampleDatabaseLauncher.open()
            }

            Button(String(localized: "Reset Sample Database...")) {
                SampleDatabaseLauncher.reset()
            }
        }

        CommandGroup(after: .newItem) {
            Button("New Tab") {
                NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .newTab))
            .disabled(!(actions?.isConnected ?? false))

            Button("New View...") {
                actions?.createView()
            }
            .disabled(!(actions?.isConnected ?? false) || actions?.isReadOnly ?? false)

            Button(openContainerMenuTitle) {
                actions?.openDatabaseSwitcher()
            }
            .optionalKeyboardShortcut(shortcut(for: .openDatabase))
            .disabled(!(actions?.isConnected ?? false) || !(actions?.supportsContainerSwitching ?? false))

            Button(String(localized: "Open File...")) {
                actions?.openSQLFile()
            }
            .optionalKeyboardShortcut(shortcut(for: .openFile))
            .disabled(!(actions?.isConnected ?? false))

            Divider()

            Button("Save Changes") {
                if keyWindowIsInspector {
                    NSApp.sendAction(#selector(InspectorViewController.saveDocument(_:)), to: nil, from: nil)
                } else {
                    actions?.saveChanges()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .saveChanges))
            // Disable only when a connection tab is focused with nothing to
            // save. When no SwiftUI content is focused (e.g. a document
            // inspector window), stay enabled so the action can route through
            // the responder chain.
            .disabled(
                keyWindowIsInspector
                    ? false
                    : (actions.map { !$0.isConnected || $0.isReadOnly || !$0.hasPendingChanges } ?? false)
            )

            Button(String(localized: "Save As...")) {
                if keyWindowIsInspector {
                    NSApp.sendAction(#selector(InspectorViewController.saveDocumentAs(_:)), to: nil, from: nil)
                } else {
                    actions?.saveFileAs()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .saveAs))
            .disabled(keyWindowIsInspector ? false : (actions.map { !$0.isConnected } ?? false))

            Button(actions != nil ? "Close Tab" : "Close") {
                if let resolved = resolvedCloseTabActions {
                    resolved.closeTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .closeTab))

            Divider()

            Button(String(localized: "Export Connections...")) {
                AppCommands.shared.exportConnections.send(())
            }

            Button(String(localized: "Import Connections...")) {
                AppCommands.shared.importConnections.send(())
            }

            Button(String(localized: "Import from Other App...")) {
                AppCommands.shared.importConnectionsFromApp.send(())
            }

            Divider()

            Button("Export...") {
                actions?.exportTables()
            }
            .optionalKeyboardShortcut(shortcut(for: .export))
            .disabled(!(actions?.isConnected ?? false))

            Button("Export Results...") {
                actions?.exportQueryResults()
            }
            .disabled(!(actions?.isConnected ?? false))

            ImportMenuItems(
                formats: actions?.availableImportFormats ?? [],
                isDisabled: !(actions?.isConnected ?? false) || (actions?.isReadOnly ?? false),
                shortcut: shortcut(for: .importData),
                action: { formatId in actions?.importTables(formatId: formatId) }
            )

            Button(String(localized: "Backup Dump\u{2026}")) {
                actions?.backupDatabase()
            }
            .disabled(!(actions?.isConnected ?? false) || !(actions?.supportsBackup ?? false))

            Button(String(localized: "Restore Dump\u{2026}")) {
                actions?.restoreDatabase()
            }
            .disabled(
                !(actions?.isConnected ?? false)
                    || !(actions?.supportsRestore ?? false)
                    || actions?.isReadOnly ?? false
            )
        }

        // Query menu
        CommandMenu("Query") {
            Button("Execute Query") {
                actions?.runQuery()
            }
            .optionalKeyboardShortcut(shortcut(for: .executeQuery))
            .disabled(!(actions?.isConnected ?? false) || !(actions?.hasQueryText ?? false))

            Button(String(localized: "Execute All Statements")) {
                actions?.runAllStatements()
            }
            .optionalKeyboardShortcut(shortcut(for: .executeAllStatements))
            .disabled(!(actions?.isConnected ?? false) || !(actions?.hasQueryText ?? false))

            Button("Explain Query") {
                actions?.explainQuery()
            }
            .optionalKeyboardShortcut(shortcut(for: .explainQuery))
            .disabled(!(actions?.isConnected ?? false) || !(actions?.hasQueryText ?? false))

            Button("Format Query") {
                actions?.formatQuery()
            }
            .optionalKeyboardShortcut(shortcut(for: .formatQuery))
            .disabled(!(actions?.isConnected ?? false) || !(actions?.hasQueryText ?? false))

            Button {
                actions?.previewSQL()
            } label: {
                if let dbType = actions?.currentDatabaseType {
                    Text(String(format: String(localized: "Preview %@"), PluginManager.shared.queryLanguageName(for: dbType)))
                } else {
                    Text("Preview SQL")
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .previewSQL))
            // Same disabled condition as the toolbar button so Cmd+Shift+P
            // doesn't open an empty preview popover when there are no
            // pending data changes to preview.
            .disabled(!(actions?.isConnected ?? false) || !(actions?.hasDataPendingChanges ?? false))

            Divider()

            Button(String(localized: "Cancel Query")) {
                actions?.cancelCurrentQuery()
            }
            .optionalKeyboardShortcut(shortcut(for: .cancelQuery))
            .disabled(!(actions?.isQueryExecuting ?? false))

            Button("Refresh") {
                actions?.refresh()
            }
            .optionalKeyboardShortcut(shortcut(for: .refresh))
            .disabled(!(actions?.isConnected ?? false))

            Button("Quick Switcher...") {
                actions?.openQuickSwitcher()
            }
            .optionalKeyboardShortcut(shortcut(for: .quickSwitcher))
            .disabled(!(actions?.isConnected ?? false))

            Divider()

            Button(String(localized: "Previous Page")) {
                actions?.goToPreviousPage()
            }
            .optionalKeyboardShortcut(shortcut(for: .previousPage))
            .disabled(!(actions?.isConnected ?? false))

            Button(String(localized: "Next Page")) {
                actions?.goToNextPage()
            }
            .optionalKeyboardShortcut(shortcut(for: .nextPage))
            .disabled(!(actions?.isConnected ?? false))

            Button(String(localized: "First Page")) {
                actions?.goToFirstPage()
            }
            .optionalKeyboardShortcut(shortcut(for: .firstPage))
            .disabled(!(actions?.isConnected ?? false))

            Button(String(localized: "Last Page")) {
                actions?.goToLastPage()
            }
            .optionalKeyboardShortcut(shortcut(for: .lastPage))
            .disabled(!(actions?.isConnected ?? false))

            Divider()

            Button(String(localized: "Save as Favorite")) {
                actions?.saveAsFavorite()
            }
            .optionalKeyboardShortcut(shortcut(for: .saveAsFavorite))
            .disabled(!(actions?.canSaveAsFavorite ?? false))

            Divider()

            Button(String(localized: "Explain with AI")) {
                actions?.aiExplainQuery()
            }
            .optionalKeyboardShortcut(shortcut(for: .aiExplainQuery))
            .disabled(!(actions?.isConnected ?? false) || !(actions?.hasQueryText ?? false))

            Button(String(localized: "Optimize with AI")) {
                actions?.aiOptimizeQuery()
            }
            .optionalKeyboardShortcut(shortcut(for: .aiOptimizeQuery))
            .disabled(!(actions?.isConnected ?? false) || !(actions?.hasQueryText ?? false))

            Divider()

            Button(String(localized: "Preview FK Reference")) {
                actions?.previewFKReference()
            }
            .optionalKeyboardShortcut(shortcut(for: .previewFKReference))
            .disabled(!(actions?.isConnected ?? false))

            Button("Switch Connection...") {
                actions?.openConnectionSwitcher()
            }
            .optionalKeyboardShortcut(shortcut(for: .switchConnection))
            .disabled(!(actions?.isConnected ?? false))
        }

        // Edit menu - Undo/Redo (smart handling for both text editor and data grid)
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                // Inspector windows and text views both handle undo: via the
                // AppKit responder chain. Data grid tabs route through actions.
                if keyWindowIsInspector ||
                    (NSApp.keyWindow?.firstResponder is NSTextView) ||
                    (NSApp.keyWindow?.firstResponder is TextView) {
                    NSApp.sendAction(#selector(TableProResponderActions.undo(_:)), to: nil, from: nil)
                } else {
                    actions?.undoChange()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .undo))

            Button("Redo") {
                if keyWindowIsInspector ||
                    (NSApp.keyWindow?.firstResponder is NSTextView) ||
                    (NSApp.keyWindow?.firstResponder is TextView) {
                    NSApp.sendAction(#selector(TableProResponderActions.redo(_:)), to: nil, from: nil)
                } else {
                    actions?.redoChange()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .redo))
        }

        PasteboardCommands(settingsManager: settingsManager, commandRegistry: commandRegistry)

        // Edit menu - Find + row operations (after pasteboard)
        CommandGroup(after: .pasteboard) {
            Divider()

            Button(String(localized: "Find...")) {
                switch commandFRoute {
                case .inspectorFilter:
                    NSApp.sendAction(#selector(InspectorViewController.toggleInspectorFilter(_:)), to: nil, from: nil)
                case .editorFind:
                    EditorEventRouter.shared.showFindPanelForKeyWindow()
                case .tableFilter:
                    break
                }
            }
            .optionalKeyboardShortcut(commandFRoute == .tableFilter ? nil : KeyboardShortcut("f", modifiers: .command))
            .disabled(commandFRoute == .tableFilter)

            Button(String(localized: "Find Next")) {
                EditorEventRouter.shared.findNext()
            }
            .optionalKeyboardShortcut(shortcut(for: .findNext))
            .disabled(!(actions?.isConnected ?? false))

            Button(String(localized: "Find Previous")) {
                EditorEventRouter.shared.findPrevious()
            }
            .optionalKeyboardShortcut(shortcut(for: .findPrevious))
            .disabled(!(actions?.isConnected ?? false))

            Divider()

            Button("Add Row") {
                actions?.addNewRow()
            }
            .optionalKeyboardShortcut(shortcut(for: .addRow))
            .disabled(!(actions?.isCurrentTabEditable ?? false) || actions?.isReadOnly ?? false)

            Button("Duplicate Row") {
                actions?.duplicateRow()
            }
            .optionalKeyboardShortcut(shortcut(for: .duplicateRow))
            .disabled(!(actions?.isCurrentTabEditable ?? false) || actions?.isReadOnly ?? false)

            Divider()

            // Table operations (work when tables selected in sidebar)
            Button("Truncate Table") {
                actions?.truncateTables()
            }
            .optionalKeyboardShortcut(shortcut(for: .truncateTable))
            .disabled(!(actions?.hasTableSelection ?? false) || actions?.isReadOnly ?? false)
        }

        // View menu
        CommandGroup(after: .sidebar) {
            Button(String(localized: "Toggle Sidebar")) {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleTableBrowser))

            Button("Toggle Inspector") {
                actions?.toggleRightSidebar()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleInspector))
            .disabled(!(actions?.isConnected ?? false))

            Divider()

            Picker(selection: sidebarLayoutBinding) {
                Text("Sidebar as List").tag(SidebarLayout.flat)
                Text("Sidebar as Tree").tag(SidebarLayout.tree)
            } label: {
                Text("Sidebar Layout")
            }
            .pickerStyle(.inline)
            .disabled(!(actions?.canSwitchSidebarLayout ?? false))

            Divider()

            Button("Toggle Filters") {
                actions?.toggleFilterPanel()
            }
            .optionalKeyboardShortcut(commandFRoute == .tableFilter ? shortcut(for: .toggleFilters) : nil)
            .disabled(commandFRoute != .tableFilter || !(actions?.isConnected ?? false))

            Button("Toggle History") {
                actions?.toggleHistoryPanel()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleHistory))
            .disabled(!(actions?.isConnected ?? false))

            Divider()

            Button("Focus Sidebar Filter") {
                actions?.focusSidebarSearch()
            }
            .optionalKeyboardShortcut(shortcut(for: .focusSidebarSearch))
            .disabled(!(actions?.isConnected ?? false))

            Button("Show Tables Sidebar") {
                actions?.showSidebarTab(.tables)
            }
            .optionalKeyboardShortcut(shortcut(for: .showSidebarTables))
            .disabled(!(actions?.isConnected ?? false))

            Button("Show Favorites Sidebar") {
                actions?.showSidebarTab(.favorites)
            }
            .optionalKeyboardShortcut(shortcut(for: .showSidebarFavorites))
            .disabled(!(actions?.isConnected ?? false))

            Divider()

            Button("Toggle Results") {
                actions?.toggleResults()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleResults))
            .disabled(!(actions?.isConnected ?? false))

            Button("Previous Result") {
                actions?.previousResultTab()
            }
            .optionalKeyboardShortcut(shortcut(for: .previousResultTab))
            .disabled(!(actions?.isConnected ?? false))

            Button("Next Result") {
                actions?.nextResultTab()
            }
            .optionalKeyboardShortcut(shortcut(for: .nextResultTab))
            .disabled(!(actions?.isConnected ?? false))

            Button("Close Result Tab") {
                actions?.closeResultTab()
            }
            .optionalKeyboardShortcut(shortcut(for: .closeResultTab))
            .disabled(!(actions?.isConnected ?? false))

            Divider()

            Button(String(localized: "View ER Diagram")) {
                actions?.showERDiagram()
            }
            .disabled(!(actions?.isConnected ?? false))

            Button(String(localized: "Server Dashboard")) {
                actions?.showServerDashboard()
            }
            .disabled(!(actions?.isConnected ?? false) || !(actions?.supportsServerDashboard ?? false))

            Divider()

            Button("Increase Text Size") {
                ThemeEngine.shared.adjustEditorFontSize(by: 1)
            }
            .keyboardShortcut("=", modifiers: .command)

            Button("Decrease Text Size") {
                ThemeEngine.shared.adjustEditorFontSize(by: -1)
            }
            .keyboardShortcut("-", modifiers: .command)
        }

        // Tab navigation shortcuts — native macOS window tabs
        CommandGroup(after: .windowArrangement) {
            // Tab switching by number (Cmd+1 through Cmd+9)
            ForEach(1...9, id: \.self) { number in
                Button("Select Tab \(number)") {
                    actions?.selectTab(number: number)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(number))),
                    modifiers: .command
                )
                .disabled(!(actions?.isConnected ?? false))
            }

            Divider()

            // Previous tab (Cmd+Shift+[) — delegate to native macOS tab switching
            Button("Show Previous Tab") {
                NSApp.sendAction(#selector(NSWindow.selectPreviousTab(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .showPreviousTab))
            .disabled(!(actions?.isConnected ?? false))

            // Next tab (Cmd+Shift+]) — delegate to native macOS tab switching
            Button("Show Next Tab") {
                NSApp.sendAction(#selector(NSWindow.selectNextTab(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .showNextTab))
            .disabled(!(actions?.isConnected ?? false))

            Divider()

            Button("Bring All to Front") {
                NSApp.arrangeInFront(nil)
            }
        }

        // Help menu — replace default "[App Name] Help" item (which calls
        // showHelp: and fails with "Help isn't available" when no Help Book
        // is registered). The search field is preserved automatically.
        CommandGroup(replacing: .help) {
            Button(String(localized: "TablePro Website")) {
                if let url = URL(string: "https://tablepro.app") { NSWorkspace.shared.open(url) }
            }

            Button(String(localized: "Documentation")) {
                if let url = URL(string: "https://docs.tablepro.app") { NSWorkspace.shared.open(url) }
            }

            Divider()

            Button("GitHub Repository") {
                if let url = URL(string: "https://github.com/TableProApp/TablePro") { NSWorkspace.shared.open(url) }
            }

            Divider()

            Button(String(localized: "Report an Issue")) {
                if let url = URL(string: "https://github.com/TableProApp/TablePro/issues") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - App

@main
struct TableProApp: App {
    // Connect AppKit delegate for proper window configuration
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    @State private var settingsManager = AppSettingsManager.shared
    @State private var updaterBridge = UpdaterBridge.shared
    @State private var commandRegistry = CommandActionsRegistry.shared

    init() {
        AIProviderRegistration.registerAll()

        // Perform startup cleanup of query history if auto-cleanup is enabled
        Task {
            await QueryHistoryManager.shared.performStartupCleanup()
        }
    }

    var body: some Scene {
        Window("Welcome to TablePro", id: SceneId.welcome) {
            WelcomeWindowView()
                .frame(width: 800, height: 480)
                .background(WindowOpenerBridge())
                .background(WindowChromeConfigurator(
                    restorable: false,
                    fullScreenable: false,
                    hideMiniaturizeButton: true,
                    hideZoomButton: true
                ))
                .environment(\.appServices, .live)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commandsRemoved()

        WindowGroup("New Connection", id: SceneId.connectionForm, for: UUID?.self) { $editingId in
            ConnectionFormView(connectionId: editingId ?? nil)
                .background(WindowOpenerBridge())
                .background(WindowChromeConfigurator(restorable: false))
                .environment(\.appServices, .live)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 600)
        .commandsRemoved()

        Window("Integrations Activity", id: SceneId.integrationsActivity) {
            IntegrationsActivityView()
                .background(WindowOpenerBridge())
                .environment(\.appServices, .live)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 600)
        .commands {
            AppMenuCommands(
                settingsManager: AppSettingsManager.shared,
                updaterBridge: updaterBridge,
                commandRegistry: commandRegistry
            )
        }

        Settings {
            SettingsView()
                .background(WindowOpenerBridge())
                .environment(updaterBridge)
                .environment(\.appServices, .live)
        }
    }
}

// MARK: - Check for Updates

/// Menu bar button that triggers Sparkle update check
struct CheckForUpdatesView: View {
    var updaterBridge: UpdaterBridge

    var body: some View {
        Button("Check for Updates...") {
            updaterBridge.checkForUpdates()
        }
        .disabled(!updaterBridge.canCheckForUpdates)
    }
}

// MARK: - MCP Server Menu Item

private struct MCPServerMenuItem: View {
    @State private var manager = MCPServerManager.shared

    var body: some View {
        Button(menuTitle) {
            WindowOpener.shared.openSettings()
        }
    }

    private var menuTitle: String {
        switch manager.state {
        case .running:
            let count = manager.connectedClients.count
            if count == 0 {
                return String(localized: "Integrations: Running")
            }
            return String(format: String(localized: "Integrations: Running (%d clients)"), count)
        case .failed:
            return String(localized: "Integrations: Failed")
        case .stopped:
            return String(localized: "Integrations: Stopped")
        case .starting:
            return String(localized: "Integrations: Starting...")
        }
    }
}
