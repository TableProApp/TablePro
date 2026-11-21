//
//  NetworkPaneView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit
import TableProSSHConfig

/// How the connection reaches its database: one transport, then how it is encrypted.
///
/// The five transports used to be five sidebar panes with an Enable switch each, so the only way
/// to find out which one was on was to visit all five, and turning on a second left the connection
/// in a state `DatabaseConnection.activeTunnelKind` reports as no transport at all. One picker
/// makes that state unrepresentable.
struct NetworkPaneView: View {
    @ObservedObject var coordinator: ConnectionFormCoordinator

    var body: some View {
        Group {
            transportPicker
            transportSections
            if coordinator.showsSSL {
                SSLSections(
                    databaseType: coordinator.network.type,
                    usesLocalSocket: coordinator.network.usesLocalSocket,
                    sslMode: sslModeBinding,
                    sslCaCertPath: $coordinator.ssl.caCertPath,
                    sslClientCertPath: $coordinator.ssl.clientCertPath,
                    sslClientKeyPath: $coordinator.ssl.clientKeyPath,
                    sslClientKeyPassphrase: $coordinator.ssl.clientKeyPassphrase
                )
            }
        }
    }

    private var sslModeBinding: Binding<SSLMode> {
        Binding(
            get: { coordinator.ssl.mode },
            set: { coordinator.ssl.select($0) }
        )
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
            Text(footerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "On the Server" runs statements on the host rather than fetching a copy, so the footer says
    /// so instead of the copy's summary, which the `.remoteFile` getter would otherwise always show.
    private var footerSummary: String {
        if coordinator.transport == .remoteFile,
           coordinator.supportsRemoteDatabaseSession,
           coordinator.ssh.state.remoteFileAccess == .onServer {
            return ConnectionTunnelKind.remoteDatabaseSession.summary
        }
        return coordinator.transport?.summary ?? directSummary
    }

    private var directSummary: String {
        ConnectionTunnelKind.directSummary(
            isFileBased: coordinator.network.connectionMode == .fileBased,
            usesLocalSocket: coordinator.network.usesLocalSocket,
            localSocketSkipsTLS: coordinator.network.localSocketSkipsTLS
        )
    }

    @ViewBuilder
    private var transportSections: some View {
        switch coordinator.transport {
        case .none:
            EmptyView()
        case .ssh:
            SSHTransportSections(coordinator: coordinator)
        case .remoteFile, .remoteDatabaseSession:
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
