//
//  TableProToolbarView.swift
//  TablePro
//
//  Main toolbar composition view combining all toolbar components.
//  This is a pure presentation view - all state is injected via bindings.
//
//  Layout:
//  - Left (.navigation): Reserved for future navigation controls
//  - Center (.principal): Environment badge + Connection status
//  - Right (.primaryAction): Execution indicator
//

import SwiftUI
import TableProPluginKit

/// Content for the principal (center) toolbar area
/// Displays environment badge, connection status, and execution indicator in a unified card
struct ToolbarPrincipalContent: View {
    var state: ConnectionToolbarState

    var body: some View {
        HStack(spacing: 10) {
            if let tagId = state.tagId,
               let tag = TagStorage.shared.tag(for: tagId)
            {
                TagBadgeView(tag: tag)
            }

            ConnectionStatusView(
                databaseType: state.databaseType,
                databaseVersion: state.databaseVersion,
                databaseName: state.databaseName,
                connectionName: state.connectionName,
                connectionState: state.connectionState,
                displayColor: state.displayColor,
                tagName: state.tagId.flatMap { TagStorage.shared.tag(for: $0)?.name },
                safeModeLevel: state.safeModeLevel
            )

            SafeModeBadgeView(safeModeLevel: Bindable(state).safeModeLevel)

            ExecutionIndicatorView(
                isExecuting: state.isExecuting,
                lastDuration: state.lastQueryDuration,
                clickHouseProgress: state.clickHouseProgress,
                lastClickHouseProgress: state.lastClickHouseProgress
            )
        }
    }
}

/// Toolbar modifier that composes all toolbar items
/// Apply this to a view to add the production toolbar
struct TableProToolbar: ViewModifier {
    @Bindable var state: ConnectionToolbarState
    @FocusedValue(\.commandActions) private var actions: MainContentCommandActions?
    @State private var showConnectionSwitcher = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                // MARK: - Navigation (Left)

                ToolbarItem(placement: .navigation) {
                    Button {
                        showConnectionSwitcher.toggle()
                    } label: {
                        Label("Connection", systemImage: "network")
                    }
                    .help(String(localized: "Switch Connection (⌘⌥C)"))
                    .popover(isPresented: $showConnectionSwitcher) {
                        ConnectionSwitcherPopover {
                            showConnectionSwitcher = false
                        }
                    }
                }

                ToolbarItem(placement: .navigation) {
                    let supportsSwitch = PluginManager.shared.supportsDatabaseSwitching(for: state.databaseType)
                    Button {
                        actions?.openDatabaseSwitcher()
                    } label: {
                        Label("Database", systemImage: "cylinder")
                    }
                    .help(String(localized: "Open Database (⌘K)"))
                    .disabled(
                        !supportsSwitch
                            || state.connectionState != .connected
                            || PluginManager.shared.connectionMode(for: state.databaseType) == .fileBased)
                    .opacity(supportsSwitch ? 1 : 0)
                    .allowsHitTesting(supportsSwitch)
                }

                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        NotificationCenter.default.post(name: .refreshData, object: nil)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help(String(localized: "Refresh (⌘R)"))
                    .disabled(state.connectionState != .connected)

                    Button {
                        actions?.saveChanges()
                    } label: {
                        Label("Save Changes", systemImage: "checkmark.circle.fill")
                    }
                    .help(String(localized: "Save Changes (⌘S)"))
                    .disabled(!state.hasPendingChanges || state.connectionState != .connected)
                    .tint(.accentColor)
                }

                // MARK: - Principal (Center)

                ToolbarItem(placement: .principal) {
                    ToolbarPrincipalContent(state: state)
                }

                // MARK: - Primary Action (Right)

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        actions?.openQuickSwitcher()
                    } label: {
                        Label("Quick Switcher", systemImage: "magnifyingglass")
                    }
                    .help(String(localized: "Quick Switcher (⇧⌘O)"))
                    .disabled(state.connectionState != .connected)

                    Button {
                        actions?.newTab()
                    } label: {
                        Label("New Tab", systemImage: "plus.rectangle")
                    }
                    .help(String(localized: "New Query Tab (⌘T)"))
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        actions?.toggleFilterPanel()
                    } label: {
                        Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .help(String(localized: "Toggle Filters (⇧⌘F)"))
                    .disabled(state.connectionState != .connected || !state.isTableTab)
                }

                ToolbarItem(placement: .primaryAction) {
                    VStack {
                        Button {
                            actions?.previewSQL()
                        } label: {
                            let langName = PluginManager.shared.queryLanguageName(for: state.databaseType)
                            Label("Preview \(langName)", systemImage: "eye")
                        }
                        .help(String(format: String(localized: "Preview %@ (⌘⇧P)"), PluginManager.shared.queryLanguageName(for: state.databaseType)))
                        .disabled(!state.hasDataPendingChanges || state.connectionState != .connected)
                    }
                    .popover(isPresented: $state.showSQLReviewPopover) {
                        SQLReviewPopover(statements: state.previewStatements, databaseType: state.databaseType)
                    }
                }

                if !state.isTableTab {
                    ToolbarItem(placement: .primaryAction) {
                        Button { actions?.toggleResults() } label: {
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

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        actions?.toggleRightSidebar()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .help(String(localized: "Toggle Inspector (⌘⌥I)"))
                }

                // MARK: - Secondary Action (Overflow)

                ToolbarItemGroup(placement: .secondaryAction) {
                    Button {
                        actions?.showServerDashboard()
                    } label: {
                        Label(String(localized: "Dashboard"), systemImage: "gauge.with.dots.needle.33percent")
                    }
                    .help(String(localized: "Server Dashboard"))
                    .disabled(state.connectionState != .connected || !(actions?.supportsServerDashboard ?? false))

                    Button {
                        actions?.toggleHistoryPanel()
                    } label: {
                        Label("History", systemImage: "clock")
                    }
                    .help(String(localized: "Toggle Query History (⌘Y)"))

                    Button {
                        actions?.exportTables()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help(String(localized: "Export Data (⌘⇧E)"))
                    .disabled(state.connectionState != .connected)

                    if PluginManager.shared.supportsImport(for: state.databaseType) {
                        Button {
                            actions?.importTables()
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .help(String(localized: "Import Data (⌘⇧I)"))
                        .disabled(state.connectionState != .connected || state.safeModeLevel.blocksAllWrites)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openConnectionSwitcher)) { _ in
                showConnectionSwitcher = true
            }
    }
}

// MARK: - View Extension

extension View {
    /// Apply the TablePro toolbar to this view
    /// - Parameter state: The toolbar state to display
    /// - Returns: View with toolbar applied
    func openTableToolbar(state: ConnectionToolbarState) -> some View {
        modifier(TableProToolbar(state: state))
    }
}

// MARK: - Preview

#Preview("With Production Tag") {
    let state = ConnectionToolbarState()
    state.tagId = ConnectionTag.presets.first { $0.name == "production" }?.id
    state.databaseType = .mariadb
    state.databaseVersion = "11.1.2"
    state.connectionName = "Production Database"
    state.connectionState = .connected
    state.displayColor = .red

    return NavigationStack {
        Text("Content")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
    .openTableToolbar(state: state)
    .frame(width: 900, height: 400)
}

#Preview("Executing Query") {
    let state = ConnectionToolbarState()
    state.tagId = ConnectionTag.presets.first { $0.name == "local" }?.id
    state.databaseType = .mysql
    state.databaseVersion = "8.0.35"
    state.connectionName = "Development"
    state.connectionState = .executing
    state.setExecuting(true)
    state.displayColor = .orange

    return NavigationStack {
        Text("Content")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
    .openTableToolbar(state: state)
    .frame(width: 900, height: 400)
}

#Preview("No Tag") {
    let state = ConnectionToolbarState()
    state.tagId = nil
    state.databaseType = .postgresql
    state.databaseVersion = "16.1"
    state.connectionName = "Analytics"
    state.connectionState = .connected
    state.displayColor = .blue

    return NavigationStack {
        Text("Content")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
    .openTableToolbar(state: state)
    .frame(width: 900, height: 400)
    .preferredColorScheme(.dark)
}
