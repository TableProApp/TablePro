//
//  TableProApp.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import CodeEditTextView
import Observation
import Sparkle
import SwiftUI
import TableProPluginKit

// MARK: - App State for Menu Commands

@MainActor
@Observable
final class AppState {
    static let shared = AppState()
    var isConnected: Bool = false
    var safeModeLevel: SafeModeLevel = .silent
    var isReadOnly: Bool { safeModeLevel.blocksAllWrites }
    var editorLanguage: EditorLanguage = .sql
    var currentDatabaseType: DatabaseType?
    var supportsDatabaseSwitching: Bool = true
    var isCurrentTabEditable: Bool = false  // True when current tab is an editable table
    var hasRowSelection: Bool = false  // True when rows are selected in data grid
    var hasTableSelection: Bool = false  // True when tables are selected in sidebar
    var isHistoryPanelVisible: Bool = false  // Global history panel visibility
    var hasQueryText: Bool = false  // True when current editor has non-empty query
    var hasStructureChanges: Bool = false  // True when structure view has pending schema changes
    var isTableTab: Bool = false  // True when current tab is a table tab (not query)
}

// MARK: - Pasteboard Commands

/// Custom Commands struct for pasteboard operations
struct PasteboardCommands: Commands {
    var appState: AppState
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
                    hasRowSelection: appState.hasRowSelection,
                    hasTableSelection: appState.hasTableSelection
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
            .disabled(!appState.hasRowSelection)

            Button("Copy as JSON") {
                actions?.copySelectedRowsAsJson()
            }
            .optionalKeyboardShortcut(shortcut(for: .copyAsJson))
            .disabled(!appState.hasRowSelection)

            Button("Paste") {
                let action = PasteboardActionRouter.resolvePasteAction(
                    firstResponder: NSApp.keyWindow?.firstResponder,
                    isCurrentTabEditable: appState.isCurrentTabEditable
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
            .disabled(!appState.isCurrentTabEditable && !appState.hasTableSelection)

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
    var appState: AppState
    var settingsManager: AppSettingsManager
    var updaterBridge: UpdaterBridge
    @FocusedValue(\.commandActions) var actions: MainContentCommandActions?

    private func shortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        settingsManager.keyboard.keyboardShortcut(for: action)
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
            Button("New Connection...") {
                NotificationCenter.default.post(name: .newConnection, object: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .newConnection))
        }

        CommandGroup(after: .newItem) {
            Button("New Tab") {
                actions?.newTab()
            }
            .optionalKeyboardShortcut(shortcut(for: .newTab))
            .disabled(!appState.isConnected)

            Button("New View...") {
                actions?.createView()
            }
            .disabled(!appState.isConnected || appState.isReadOnly)

            Button("Open Database...") {
                actions?.openDatabaseSwitcher()
            }
            .optionalKeyboardShortcut(shortcut(for: .openDatabase))
            .disabled(!appState.isConnected || !appState.supportsDatabaseSwitching)

            Button(String(localized: "Open File...")) {
                actions?.openSQLFile()
            }
            .optionalKeyboardShortcut(shortcut(for: .openFile))
            .disabled(!appState.isConnected)

            Button("Switch Connection...") {
                NotificationCenter.default.post(name: .openConnectionSwitcher, object: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .switchConnection))
            .disabled(!appState.isConnected)

            Button("Quick Switcher...") {
                actions?.openQuickSwitcher()
            }
            .optionalKeyboardShortcut(shortcut(for: .quickSwitcher))
            .disabled(!appState.isConnected)

            Divider()

            Button("Save Changes") {
                actions?.saveChanges()
            }
            .optionalKeyboardShortcut(shortcut(for: .saveChanges))
            .disabled(!appState.isConnected || appState.isReadOnly)

            Button(String(localized: "Save As...")) {
                actions?.saveFileAs()
            }
            .optionalKeyboardShortcut(shortcut(for: .saveAs))
            .disabled(!appState.isConnected)

            Button {
                actions?.previewSQL()
            } label: {
                if let dbType = appState.currentDatabaseType {
                    Text("Preview \(PluginManager.shared.queryLanguageName(for: dbType))")
                } else {
                    Text("Preview SQL")
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .previewSQL))
            .disabled(!appState.isConnected)

            Button("Close Tab") {
                if let actions {
                    actions.closeTab()
                } else {
                    NSApp.keyWindow?.close()
                }
            }
            .optionalKeyboardShortcut(shortcut(for: .closeTab))

            Divider()

            Button("Refresh") {
                NotificationCenter.default.post(name: .refreshData, object: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .refresh))
            .disabled(!appState.isConnected)

            Button("Explain Query") {
                actions?.explainQuery()
            }
            .optionalKeyboardShortcut(shortcut(for: .explainQuery))
            .disabled(!appState.isConnected || !appState.hasQueryText)

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
            .disabled(!appState.isConnected)

            Button("Export Results...") {
                actions?.exportQueryResults()
            }
            .disabled(!appState.isConnected)

            if appState.currentDatabaseType.map({ PluginManager.shared.supportsImport(for: $0) }) ?? true {
                Button("Import...") {
                    actions?.importTables()
                }
                .optionalKeyboardShortcut(shortcut(for: .importData))
                .disabled(!appState.isConnected || appState.isReadOnly)
            }
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
        PasteboardCommands(appState: appState, settingsManager: settingsManager)

        // Edit menu - row operations (after pasteboard)
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Add Row") {
                actions?.addNewRow()
            }
            .optionalKeyboardShortcut(shortcut(for: .addRow))
            .disabled(!appState.isCurrentTabEditable || appState.isReadOnly)

            Button("Duplicate Row") {
                actions?.duplicateRow()
            }
            .optionalKeyboardShortcut(shortcut(for: .duplicateRow))
            .disabled(!appState.isCurrentTabEditable || appState.isReadOnly)

            Divider()

            // Table operations (work when tables selected in sidebar)
            Button("Truncate Table") {
                actions?.truncateTables()
            }
            .optionalKeyboardShortcut(shortcut(for: .truncateTable))
            .disabled(!appState.hasTableSelection || appState.isReadOnly)
        }

        // View menu
        CommandGroup(after: .sidebar) {
            Button("Toggle Table Browser") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleTableBrowser))
            .disabled(!appState.isConnected)

            Button("Toggle Inspector") {
                actions?.toggleRightSidebar()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleInspector))
            .disabled(!appState.isConnected)

            Divider()

            Button("Toggle Filters") {
                actions?.toggleFilterPanel()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleFilters))
            .disabled(!appState.isConnected || !appState.isTableTab)

            Button("Toggle History") {
                actions?.toggleHistoryPanel()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleHistory))
            .disabled(!appState.isConnected)

            Divider()

            Button("Toggle Results") {
                actions?.toggleResults()
            }
            .optionalKeyboardShortcut(shortcut(for: .toggleResults))
            .disabled(!appState.isConnected)

            Button("Previous Result") {
                actions?.previousResultTab()
            }
            .optionalKeyboardShortcut(shortcut(for: .previousResultTab))
            .disabled(!appState.isConnected)

            Button("Next Result") {
                actions?.nextResultTab()
            }
            .optionalKeyboardShortcut(shortcut(for: .nextResultTab))
            .disabled(!appState.isConnected)

            Button("Close Result Tab") {
                actions?.closeResultTab()
            }
            .optionalKeyboardShortcut(shortcut(for: .closeResultTab))
            .disabled(!appState.isConnected)

            Divider()

            Button("Zoom In") {
                ThemeEngine.shared.adjustEditorFontSize(by: 1)
            }
            .keyboardShortcut("=", modifiers: .command)

            Button("Zoom Out") {
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
                .disabled(!appState.isConnected)
            }

            Divider()

            // Previous tab (Cmd+Shift+[) — delegate to native macOS tab switching
            Button("Show Previous Tab") {
                NSApp.sendAction(#selector(NSWindow.selectPreviousTab(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .showPreviousTabBrackets))
            .disabled(!appState.isConnected)

            // Next tab (Cmd+Shift+]) — delegate to native macOS tab switching
            Button("Show Next Tab") {
                NSApp.sendAction(#selector(NSWindow.selectNextTab(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .showNextTabBrackets))
            .disabled(!appState.isConnected)

            // Previous tab (Cmd+Option+Left)
            Button("Previous Tab") {
                NSApp.sendAction(#selector(NSWindow.selectPreviousTab(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .previousTabArrows))
            .disabled(!appState.isConnected)

            // Next tab (Cmd+Option+Right)
            Button("Next Tab") {
                NSApp.sendAction(#selector(NSWindow.selectNextTab(_:)), to: nil, from: nil)
            }
            .optionalKeyboardShortcut(shortcut(for: .nextTabArrows))
            .disabled(!appState.isConnected)
        }

        // Help menu
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

            Button(String(localized: "Sponsor TablePro")) {
                if let url = URL(string: "https://github.com/sponsors/datlechin") { NSWorkspace.shared.open(url) }
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

        // Main Window - opens when connecting to database
        // Each native window-tab gets its own ContentView with independent state.
        WindowGroup(id: "main", for: EditorTabPayload.self) { $payload in
            ContentView(payload: payload)
                .environment(AppState.shared)
                .background(OpenWindowHandler())
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1_200, height: 800)

        // Settings Window - opens with Cmd+,
        Settings {
            SettingsView()
                .environment(updaterBridge)
        }

        .commands {
            AppMenuCommands(
                appState: AppState.shared,
                settingsManager: AppSettingsManager.shared,
                updaterBridge: updaterBridge
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
                    openWindow(id: "main", value: payload)
                } else if let connectionId = notification.object as? UUID {
                    openWindow(id: "main", value: EditorTabPayload(connectionId: connectionId))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
                openSettings()
            }
    }
}
