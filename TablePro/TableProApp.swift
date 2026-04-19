//
//  TableProApp.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import CodeEditTextView
import Observation
import os
import Sparkle
import SwiftUI
import TableProPluginKit

// MARK: - Pasteboard Commands

/// Custom Commands struct for pasteboard operations
struct PasteboardCommands: Commands {
    var settingsManager: AppSettingsManager
    @FocusedValue(\.commandActions) var actions: MainContentCommandActions?

    /// Build a SwiftUI KeyboardShortcut from keyboard settings
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
                let action = PasteboardActionRouter.resolveCopyAction(
                    firstResponder: NSApp.keyWindow?.firstResponder,
                    hasRowSelection: actions?.hasRowSelection ?? false,
                    hasTableSelection: actions?.hasTableSelection ?? false
                )
                switch action {
                case .textCopy:
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                case .copyRows:
                    actions?.copySelectedRows()
                case .copyTableNames:
                    actions?.copyTableNames()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .copy))

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
                let action = PasteboardActionRouter.resolvePasteAction(
                    firstResponder: NSApp.keyWindow?.firstResponder,
                    isCurrentTabEditable: actions?.isCurrentTabEditable ?? false
                )
                switch action {
                case .textPaste:
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                case .pasteRows:
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
                // Use responder chain - cancelOperation is the standard ESC action
                NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .clearSelection))
        }
    }
}

// MARK: - App Menu Commands

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

    private func shortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        settingsManager.keyboard.keyboardShortcut(for: action)
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

    var body: some Commands {
        // Custom About window + Check for Updates
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About TablePro")) {
                AboutWindowController.shared.showAboutPanel()
            }
            CheckForUpdatesView(updaterBridge: updaterBridge)
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
        //    - refreshData (Sidebar + Coordinator + StructureView)
        //    - Legitimate broadcasts where multiple views respond

        // File menu
        CommandGroup(replacing: .newItem) {
            Button("Manage Connections") {
                NotificationCenter.default.post(name: .newConnection, object: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .manageConnections))
        }

        CommandGroup(after: .newItem) {
            Button("New Tab") {
                actions?.newTab()
            }
            .optionalKeyboardShortcut(shortcut(for: .newTab))
            .disabled(!(actions?.isConnected ?? false))

            Button("New View...") {
                actions?.createView()
            }
            .disabled(!(actions?.isConnected ?? false) || actions?.isReadOnly ?? false)

            Button("Open Database...") {
                actions?.openDatabaseSwitcher()
            }
            .optionalKeyboardShortcut(shortcut(for: .openDatabase))
            .disabled(!(actions?.isConnected ?? false) || !(actions?.supportsDatabaseSwitching ?? false))

            Button(String(localized: "Open File...")) {
                actions?.openSQLFile()
            }
            .optionalKeyboardShortcut(shortcut(for: .openFile))
            .disabled(!(actions?.isConnected ?? false))

            Divider()

            Button("Save Changes") {
                actions?.saveChanges()
            }
            .optionalKeyboardShortcut(shortcut(for: .saveChanges))
            // Match toolbar: also disable when no pending changes — avoids
            // a no-op Cmd+S when nothing has been edited.
            .disabled(
                !(actions?.isConnected ?? false)
                    || actions?.isReadOnly ?? false
                    || !(actions?.hasPendingChanges ?? false)
            )

            Button(String(localized: "Save As...")) {
                actions?.saveFileAs()
            }
            .optionalKeyboardShortcut(shortcut(for: .saveAs))
            .disabled(!(actions?.isConnected ?? false))

            Button(actions != nil ? "Close Tab" : "Close") {
                if let resolved = resolvedCloseTabActions {
                    resolved.closeTab()
                } else if let window = NSApp.keyWindow {
                    if window.identifier?.rawValue.hasPrefix("main") == true,
                       let coordinator = MainContentCoordinator.coordinator(forWindow: window) {
                        coordinator.commandActions?.closeTab()
                    } else {
                        window.performClose(nil)
                    }
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .closeTab))

            Divider()

            Button(String(localized: "Export Connections...")) {
                NotificationCenter.default.post(name: .exportConnections, object: nil)
            }

            Button(String(localized: "Import Connections...")) {
                NotificationCenter.default.post(name: .importConnections, object: nil)
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

            Button("Import...") {
                actions?.importTables()
            }
            .optionalKeyboardShortcut(shortcut(for: .importData))
            .disabled(
                !(actions?.isConnected ?? false)
                    || actions?.isReadOnly ?? false
                    || !(actions.map { PluginManager.shared.supportsImport(for: $0.currentDatabaseType) } ?? true)
            )
        }

        // Query menu
        CommandMenu("Query") {
            Button("Execute Query") {
                actions?.runQuery()
            }
            .keyboardShortcut(.return, modifiers: .command)
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
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!(actions?.isQueryExecuting ?? false))

            Button("Refresh") {
                NotificationCenter.default.post(name: .refreshData, object: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .refresh))
            .disabled(!(actions?.isConnected ?? false))

            Button("Quick Switcher...") {
                actions?.openQuickSwitcher()
            }
            .optionalKeyboardShortcut(shortcut(for: .quickSwitcher))
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
                NotificationCenter.default.post(name: .openConnectionSwitcher, object: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .switchConnection))
            .disabled(!(actions?.isConnected ?? false))
        }

        // Edit menu - Undo/Redo (smart handling for both text editor and data grid)
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                // Check if first responder is a text view (SQL editor)
                if let firstResponder = NSApp.keyWindow?.firstResponder,
                   firstResponder is NSTextView || firstResponder is TextView {
                    // Send undo: (with colon) through responder chain —
                    // CodeEditTextView.TextView responds to undo: via @objc func undo(_:)
                    NSApp.sendAction(#selector(TableProResponderActions.undo(_:)), to: nil, from: nil)
                } else {
                    // Data grid undo
                    actions?.undoChange()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .undo))

            Button("Redo") {
                // Check if first responder is a text view (SQL editor)
                if let firstResponder = NSApp.keyWindow?.firstResponder,
                   firstResponder is NSTextView || firstResponder is TextView {
                    // Send redo: (with colon) through responder chain
                    NSApp.sendAction(#selector(TableProResponderActions.redo(_:)), to: nil, from: nil)
                } else {
                    // Data grid redo
                    actions?.redoChange()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .redo))
        }

        // Edit menu - pasteboard commands with FocusedValue support
        PasteboardCommands(settingsManager: settingsManager)

        // Edit menu - row operations (after pasteboard)
        CommandGroup(after: .pasteboard) {
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

            Button("Toggle Filters") {
                actions?.toggleFilterPanel()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleFilters))
            .disabled(!(actions?.isConnected ?? false) || !(actions?.isTableTab ?? false))

            Button("Toggle History") {
                actions?.toggleHistoryPanel()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleHistory))
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

        // Help menu — append after system-provided search field
        CommandGroup(after: .help) {
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
    @State private var updaterBridge = UpdaterBridge()
    @State private var commandRegistry = CommandActionsRegistry.shared

    init() {
        // Perform startup cleanup of query history if auto-cleanup is enabled
        Task { @MainActor in
            QueryHistoryManager.shared.performStartupCleanup()
        }
    }

    var body: some Scene {
        // Welcome Window - opens on launch (must be first Window scene so SwiftUI
        // restores it by default when clicking the dock icon)
        Window("Welcome to TablePro", id: "welcome") {
            WelcomeWindowView()
                .background(OpenWindowHandler())  // Handle window notifications from startup
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 700, height: 450)

        // Connection Form Window - opens when creating/editing a connection
        WindowGroup(id: "connection-form", for: UUID?.self) { $connectionId in
            ConnectionFormView(connectionId: connectionId ?? nil)
        }
        .windowResizability(.contentSize)

        // NOTE (prototype): main windows are now created imperatively via
        // MainWindowFactory → NSWindow + NSHostingController. The retired
        // `WindowGroup(id:"main", for: EditorTabPayload.self)` caused SwiftUI to
        // re-instantiate ContentView for every historical payload on every scene
        // phase diff (5-7 phantom inits per open). AppKit-native windows avoid
        // that and eliminate the 68-437ms openWindow() latency.

        // Settings Window - opens with Cmd+,
        Settings {
            SettingsView()
                .environment(updaterBridge)
        }

        .commands {
            AppMenuCommands(
                settingsManager: AppSettingsManager.shared,
                updaterBridge: updaterBridge,
                commandRegistry: commandRegistry
            )
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    // Connection lifecycle
    static let newConnection = Notification.Name("newConnection")
    static let openConnectionSwitcher = Notification.Name("openConnectionSwitcher")

    // Multi-listener broadcasts (Sidebar + Coordinator + StructureView)
    static let refreshData = Notification.Name("refreshData")

    // Data operations (still posted by DataGrid / context menus)
    static let deleteSelectedRows = Notification.Name("deleteSelectedRows")
    static let addNewRow = Notification.Name("addNewRow")
    static let duplicateRow = Notification.Name("duplicateRow")
    static let copySelectedRows = Notification.Name("copySelectedRows")
    static let pasteRows = Notification.Name("pasteRows")

    // Sidebar operations (still posted by SidebarView / ConnectionStatusView)
    static let openDatabaseSwitcher = Notification.Name("openDatabaseSwitcher")

    // File opening notifications
    static let openSQLFiles = Notification.Name("openSQLFiles")

    // Window lifecycle notifications
    static let mainWindowWillClose = Notification.Name("mainWindowWillClose")
    static let openMainWindow = Notification.Name("openMainWindow")
    static let openWelcomeWindow = Notification.Name("openWelcomeWindow")

    // Database URL handling notifications
    static let switchSchemaFromURL = Notification.Name("switchSchemaFromURL")
    static let applyURLFilter = Notification.Name("applyURLFilter")
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

// MARK: - Open Window Handler

/// Helper view that listens for window open notifications
private struct OpenWindowHandler: View {
    @Environment(\.openWindow)
    private var openWindow
    @Environment(\.openSettings)
    private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                // Store openWindow action for imperative access (e.g., from MainContentCommandActions)
                WindowOpener.shared.openWindow = openWindow
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWelcomeWindow)) { _ in
                openWindow(id: "welcome")
            }
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { notification in
                if let payload = notification.object as? EditorTabPayload {
                    WindowManager.shared.openTab(payload: payload)
                } else if let connectionId = notification.object as? UUID {
                    WindowManager.shared.openTab(payload: EditorTabPayload(connectionId: connectionId))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
                openSettings()
            }
    }
}
