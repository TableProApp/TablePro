//
//  MainWindowToolbar+Buttons.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProPluginKit

struct ConnectionToolbarButton: View {
    @Bindable var coordinator: MainContentCoordinator

    var body: some View {
        Button {
            coordinator.commandActions?.openConnectionSwitcher()
        } label: {
            Label("Connection", systemImage: "network")
        }
        .help(AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Switch Connection"), for: .switchConnection))
        .popover(isPresented: $coordinator.isConnectionSwitcherShown, arrowEdge: .bottom) {
            ConnectionSwitcherPopover()
        }
    }
}

struct DatabaseToolbarButton: View {
    @Bindable var coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        let supportsSwitch = PluginManager.shared.supportsContainerSwitching(for: state.databaseType)
        let containerName = PluginManager.shared.containerEntityName(for: state.databaseType)
        if supportsSwitch {
            Button {
                coordinator.commandActions?.openDatabaseSwitcher()
            } label: {
                Label(containerName, systemImage: "cylinder")
            }
            .help(AppSettingsManager.shared.keyboard.shortcutHint(String(format: String(localized: "Open %@"), containerName), for: .openDatabase))
            .disabled(
                state.connectionState != .connected
                    || PluginManager.shared.connectionMode(for: state.databaseType) == .fileBased
            )
            .popover(isPresented: $coordinator.isDatabaseSwitcherShown, arrowEdge: .bottom) {
                DatabaseSwitcherPopoverHost(coordinator: coordinator)
            }
        }
    }
}

struct SessionContextToolbarButton: View {
    @Bindable var coordinator: MainContentCoordinator

    var body: some View {
        HStack(spacing: 4) {
            ForEach(coordinator.sessionContexts) { context in
                Menu {
                    ForEach(context.availableValues, id: \.self) { value in
                        Button {
                            Task { await coordinator.switchSessionContext(id: context.id, to: value) }
                        } label: {
                            if value == context.currentValue {
                                Label(value, systemImage: "checkmark")
                            } else {
                                Text(value)
                            }
                        }
                    }
                } label: {
                    Label(context.currentValue ?? context.label, systemImage: context.iconName)
                }
                .help(context.label)
            }
        }
        .task(id: coordinator.toolbarState.connectionState) {
            await coordinator.loadSessionContexts()
        }
    }
}

struct RefreshToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        Button {
            coordinator.commandActions?.refresh()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help(AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Refresh"), for: .refresh))
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
        .help(AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Save Changes"), for: .saveChanges))
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
        .help(AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Quick Switcher"), for: .quickSwitcher))
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
        .help(AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "New Query Tab"), for: .newTab))
        .disabled(state.connectionState != .connected)
    }
}

struct PreviewSQLToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        let langName = PluginManager.shared.queryLanguageName(for: state.databaseType)
        let previewLabel = String(format: String(localized: "Preview %@"), langName)
        Button {
            coordinator.commandActions?.previewSQL()
        } label: {
            Label(previewLabel, systemImage: "eye")
        }
        .help(AppSettingsManager.shared.keyboard.shortcutHint(previewLabel, for: .previewSQL))
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
        .help(AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Toggle Results"), for: .toggleResults))
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
        .help(AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Toggle Query History"), for: .toggleHistory))
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
        .help(AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Export Data"), for: .export))
        .disabled(state.connectionState != .connected)
    }
}

struct ImportToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        let state = coordinator.toolbarState
        if PluginManager.shared.supportsImport(for: state.databaseType) {
            let formats = PluginManager.shared.importFormatOptions(for: state.databaseType)
            let isDisabled = state.connectionState != .connected || state.safeModeLevel.blocksAllWrites
            if formats.count <= 1 {
                Button {
                    coordinator.commandActions?.importTables(formatId: formats.first?.id ?? "")
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help(AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Import Data"), for: .importData))
                .disabled(isDisabled || formats.isEmpty)
            } else {
                Menu {
                    ForEach(formats) { format in
                        Button(format.submenuLabel) {
                            coordinator.commandActions?.importTables(formatId: format.id)
                        }
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help(AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Import Data"), for: .importData))
                .disabled(isDisabled)
            }
        }
    }
}
