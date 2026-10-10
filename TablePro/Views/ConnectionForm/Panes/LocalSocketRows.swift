//
//  LocalSocketRows.swift
//  TablePro
//

import SwiftUI

struct LocalSocketEndpointPicker: View {
    @ObservedObject var coordinator: ConnectionFormCoordinator

    var body: some View {
        Picker(String(localized: "Connect Using"), selection: endpointBinding) {
            Text(String(localized: "Host and Port")).tag(NetworkPaneViewModel.Endpoint.hostAndPort)
            Text(String(localized: "Socket")).tag(NetworkPaneViewModel.Endpoint.localSocket)
        }
        .accessibilityIdentifier("connection-form-endpoint")
    }

    private var endpointBinding: Binding<NetworkPaneViewModel.Endpoint> {
        Binding(
            get: { coordinator.network.endpoint },
            set: { coordinator.selectEndpoint($0) }
        )
    }
}

struct LocalSocketPathField: View {
    @ObservedObject var coordinator: ConnectionFormCoordinator

    var body: some View {
        TextField(
            String(localized: "Socket"),
            text: $coordinator.network.localSocketPath,
            prompt: Text(coordinator.network.localSocketPrompt)
        )
        .accessibilityIdentifier("connection-form-socket-path")
    }
}

struct LocalSocketFooter: View {
    let status: LocalSocketFileStatus?

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("connection-form-socket-status")
    }

    private var message: String {
        switch status {
        case .missing:
            return String(localized: "Nothing is at this path. Start the server, or check the path.")
        case .notSocket:
            return String(localized: "This file is not a socket.")
        case .socket, .none:
            return String(localized: "The server's socket file on this Mac. SELECT @@socket in the mysql client shows it.")
        }
    }
}
