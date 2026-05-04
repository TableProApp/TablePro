//
//  ConnectionFormView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct ConnectionFormView: View {
    let connectionId: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: ConnectionFormCoordinator?

    var body: some View {
        Group {
            if let coordinator {
                contentView(coordinator: coordinator)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, idealWidth: 820)
        .frame(minHeight: 560, idealHeight: 600)
        .task {
            if coordinator == nil {
                let pendingType = connectionId == nil
                    ? PendingNewConnectionType.shared.consume()
                    : nil
                let newCoordinator = ConnectionFormCoordinator(
                    connectionId: connectionId,
                    initialType: pendingType
                )
                newCoordinator.dismissAction = { dismiss() }
                newCoordinator.load()
                newCoordinator.detectClipboardConnectionStringIfNeeded()
                coordinator = newCoordinator
            }
        }
    }

    @ViewBuilder
    private func contentView(coordinator: ConnectionFormCoordinator) -> some View {
        @Bindable var bindable = coordinator

        NavigationSplitView {
            ConnectionFormSidebar(coordinator: coordinator)
        } detail: {
            ConnectionFormDetail(coordinator: coordinator)
        }
        .navigationTitle(
            coordinator.isNew
                ? String(localized: "New Connection")
                : String(localized: "Edit Connection")
        )
        .toolbar {
            ConnectionFormToolbar(coordinator: coordinator)
        }
        .sheet(isPresented: $bindable.showURLImport) {
            ImportFromURLSheet(coordinator: coordinator)
        }
        .sheet(isPresented: $bindable.showTypeChooser) {
            DatabaseTypeChooserSheet(
                initialType: coordinator.network.type,
                onSelected: { newType in
                    coordinator.network.setType(newType)
                },
                onCancel: {}
            )
        }
        .sheet(item: $bindable.pluginDiagnostic) { item in
            PluginDiagnosticSheet(item: item) {
                coordinator.pluginDiagnostic = nil
            }
        }
        .pluginInstallPrompt(connection: $bindable.pluginInstallConnection) { connection in
            coordinator.connectAfterInstall(connection)
        }
    }
}

private struct ConnectionFormDetail: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        Group {
            switch coordinator.selectedPane {
            case .general:
                GeneralPaneView(coordinator: coordinator)
            case .ssh:
                SSHPaneView(coordinator: coordinator)
            case .ssl:
                SSLPaneView(coordinator: coordinator)
            case .customization:
                CustomizationPaneView(coordinator: coordinator)
            case .advanced:
                AdvancedPaneView(coordinator: coordinator)
            }
        }
        .navigationSplitViewColumnWidth(min: 480, ideal: 580)
    }
}
