//
//  MainWindowToolbar+Buttons.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProPluginKit

struct ConnectionToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        Button {
            coordinator.commandActions?.openConnectionSwitcher()
        } label: {
            Label("Connection", systemImage: "network")
        }
        .help(String(localized: "Switch Connection (⌘⌥C)"))
    }
}

struct DatabaseToolbarButton: View {
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

struct RefreshToolbarButton: View {
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

struct SaveChangesToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        Button {
            coordinator.commandActions?.saveChanges()
        } label: {
            Label("Save Changes", systemImage: "checkmark.circle.fill")
        }
        .help(String(localized: "Save Changes (⌘S)"))
        .disabled(
            !state.hasPendingChanges
                || state.connectionState != .connected
                || state.safeModeLevel.blocksAllWrites
        )
        .tint(.accentColor)
    }
}

struct QuickSwitcherToolbarButton: View {
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

struct NewTabToolbarButton: View {
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

struct PreviewSQLToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        Button {
            coordinator.commandActions?.previewSQL()
        } label: {
            let langName = PluginManager.shared.queryLanguageName(for: state.databaseType)
            Label(String(format: String(localized: "Preview %@"), langName), systemImage: "eye")
        }
        .help(String(format: String(localized: "Preview %@ (⌘⇧P)"), PluginManager.shared.queryLanguageName(for: state.databaseType)))
        .disabled(!state.hasDataPendingChanges || state.connectionState != .connected)
    }
}

struct ResultsToolbarButton: View {
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
        .disabled(state.connectionState != .connected || state.isTableTab)
    }
}

struct DashboardToolbarButton: View {
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

struct HistoryToolbarButton: View {
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

struct ExportToolbarButton: View {
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

struct ImportToolbarButton: View {
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
