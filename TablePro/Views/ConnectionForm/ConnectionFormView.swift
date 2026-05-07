//
//  ConnectionFormView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct ConnectionFormView: View {
    let connectionId: UUID?

    @State private var coordinator: ConnectionFormCoordinator
    @Environment(\.dismiss) private var dismiss

    init(connectionId: UUID?) {
        self.connectionId = connectionId
        let pendingImport = connectionId == nil
            ? PendingNewConnectionImport.shared.consume()
            : nil
        let pendingType = connectionId == nil
            ? PendingNewConnectionType.shared.consume()
            : nil
        _coordinator = State(initialValue: ConnectionFormCoordinator(
            connectionId: connectionId,
            initialType: pendingType,
            initialParsedURL: pendingImport
        ))
    }

    var body: some View {
        @Bindable var bindable = coordinator

        return NavigationSplitView {
            ConnectionFormSidebar(coordinator: coordinator)
        } detail: {
            ConnectionFormDetail(coordinator: coordinator)
        }
        .frame(minWidth: 720, idealWidth: 820)
        .frame(minHeight: 560, idealHeight: 600)
        .navigationTitle(
            coordinator.isNew
                ? String(format: String(localized: "New %@ Connection"), coordinator.network.type.rawValue)
                : String(format: String(localized: "Edit %@ Connection"), coordinator.network.type.rawValue)
        )
        .toolbar {
            ConnectionFormToolbar(coordinator: coordinator)
        }
        .sheet(item: $bindable.pluginDiagnostic) { item in
            PluginDiagnosticSheet(item: item) {
                coordinator.pluginDiagnostic = nil
            }
        }
        .pluginInstallPrompt(connection: $bindable.pluginInstallConnection) { connection in
            coordinator.connectAfterInstall(connection)
        }
        .alert(
            String(localized: "Save Failed"),
            isPresented: Binding(
                get: { coordinator.saveError != nil },
                set: { if !$0 { coordinator.saveError = nil } }
            ),
            presenting: coordinator.saveError
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) {
                coordinator.saveError = nil
            }
        } message: { error in
            Text(error)
        }
        .task {
            coordinator.dismissAction = { dismiss() }
            coordinator.detectClipboardConnectionStringIfNeeded()
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
            case .aiRules:
                AIRulesPaneView(coordinator: coordinator)
            }
        }
        .navigationSplitViewColumnWidth(min: 480, ideal: 580)
    }
}
