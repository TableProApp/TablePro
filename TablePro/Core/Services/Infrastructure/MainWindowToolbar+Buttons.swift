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
        /// The toolbar runs icon only, and a hosted view has to honour that itself. The label is a
        /// fixed word rather than the connection's name, which the centred status item already
        /// shows, so drawing it put a second idiom beside the native icon-only items for nothing.
        .labelStyle(.iconOnly)
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
            .labelStyle(.iconOnly)
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

/// Thin wrappers so the toolbar's hosted content follows the window's subject instead of capturing
/// one connection. Reading `subject.coordinator` inside `body` is what registers the observation,
/// and the `id` is what makes the connection's identity the view's identity. The `if let` alone
/// keeps one branch across a repoint, so SwiftUI carried the outgoing connection's `@State` over
/// and left its `task(id:)` running instead of restarting it for the connection that arrived.
internal struct ConnectionToolbarSubjectButton: View {
    internal let subject: ToolbarSubject

    internal var body: some View {
        if let coordinator = subject.coordinator {
            ConnectionToolbarButton(coordinator: coordinator)
                .id(coordinator.connectionId)
        }
    }
}

internal struct DatabaseToolbarSubjectButton: View {
    internal let subject: ToolbarSubject

    internal var body: some View {
        if let coordinator = subject.coordinator {
            DatabaseToolbarButton(coordinator: coordinator)
                .id(coordinator.connectionId)
        }
    }
}

internal struct SessionContextToolbarSubjectButton: View {
    internal let subject: ToolbarSubject

    internal var body: some View {
        if let coordinator = subject.coordinator {
            SessionContextToolbarButton(coordinator: coordinator)
                .id(coordinator.connectionId)
        }
    }
}

/// The centred status item. `ConnectionToolbarState` is a reference type, so this reads it from the
/// subject each time rather than being handed one connection's instance at build time.
internal struct ToolbarPrincipalSubjectContent: View {
    internal let subject: ToolbarSubject

    internal var body: some View {
        if let coordinator = subject.coordinator {
            ToolbarPrincipalContent(
                state: coordinator.toolbarState,
                connectionId: coordinator.connection.id,
                coordinator: coordinator,
                onCancelQuery: { [weak coordinator] in coordinator?.cancelCurrentQuery() },
                onSafeModeChange: { [weak coordinator] level in coordinator?.setSafeModeLevel(level) }
            )
            .id(coordinator.connectionId)
        }
    }
}
