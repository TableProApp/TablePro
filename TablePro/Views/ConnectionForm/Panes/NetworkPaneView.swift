//
//  NetworkPaneView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// How the connection reaches its database: one transport, then how it is encrypted.
///
/// The five transports used to be five sidebar panes with an Enable switch each, so the only way
/// to find out which one was on was to visit all five, and turning on a second left the connection
/// in a state `DatabaseConnection.activeTunnelKind` reports as no transport at all. One picker
/// makes that state unrepresentable.
struct NetworkPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        Form {
            transportPicker
            transportSections
            if coordinator.supportsSSL {
                SSLSections(
                    databaseType: coordinator.network.type,
                    sslMode: $coordinator.ssl.mode,
                    sslCaCertPath: $coordinator.ssl.caCertPath,
                    sslClientCertPath: $coordinator.ssl.clientCertPath,
                    sslClientKeyPath: $coordinator.ssl.clientKeyPath,
                    sslClientKeyPassphrase: $coordinator.ssl.clientKeyPassphrase
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var transportPicker: some View {
        Section {
            Picker(String(localized: "Connect via"), selection: $coordinator.transport) {
                ForEach(coordinator.availableTransports, id: \.self) { transport in
                    Text(transport?.displayName ?? ConnectionTunnelKind.directDisplayName)
                        .tag(transport)
                }
            }
            .accessibilityIdentifier("connection-form-transport")
        } footer: {
            Text(coordinator.transport?.summary ?? directSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var directSummary: String {
        ConnectionTunnelKind.directSummary(
            isFileBased: coordinator.network.connectionMode == .fileBased
        )
    }

    @ViewBuilder
    private var transportSections: some View {
        switch coordinator.transport {
        case .none:
            EmptyView()
        case .ssh:
            SSHTransportSections(coordinator: coordinator)
        case .remoteFile:
            RemoteFileTransportSections(coordinator: coordinator)
        case .cloudflare:
            CloudflareTransportSections(coordinator: coordinator)
        case .cloudSQLProxy:
            CloudSQLProxyTransportSections(coordinator: coordinator)
        case .socksProxy:
            SOCKSProxyTransportSections(coordinator: coordinator)
        case .tunnelCommand:
            TunnelCommandTransportSections(coordinator: coordinator)
        }
    }
}
