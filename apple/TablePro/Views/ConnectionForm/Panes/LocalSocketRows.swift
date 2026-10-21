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
        let suggestions = coordinator.network.localSocketSuggestions
        if suggestions.isEmpty {
            TextField(
                String(localized: "Socket"),
                text: $coordinator.network.localSocketPath,
                prompt: Text(coordinator.network.localSocketPrompt)
            )
            .accessibilityIdentifier("connection-form-socket-path")
        } else {
            LabeledContent(String(localized: "Socket")) {
                SuggestionComboBox(
                    suggestions: { suggestions },
                    placeholder: coordinator.network.localSocketPrompt,
                    accessibilityLabel: String(localized: "Socket"),
                    accessibilityIdentifier: "connection-form-socket-path",
                    value: $coordinator.network.localSocketPath
                )
            }
        }
    }
}

struct LocalSocketFooter: View {
    let status: LocalSocketFileStatus?
    var socketFile: String?
    var isDirectory = false

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("connection-form-socket-status")
    }

    private var message: String {
        isDirectory ? directoryMessage : fileMessage
    }

    private var fileMessage: String {
        switch status {
        case .missing:
            return String(localized: "Nothing is at this path. Start the server, or check the path.")
        case .notSocket:
            return String(localized: "This file is not a socket.")
        case .socket, .none:
            return String(localized: "The server's socket file on this Mac. SELECT @@socket in the mysql client shows it.")
        }
    }

    private var directoryMessage: String {
        guard let socketFile else {
            return String(localized: """
                The folder with the server's socket, or the socket file. SHOW unix_socket_directories \
                in psql lists the folders.
                """)
        }
        let file = (socketFile as NSString).abbreviatingWithTildeInPath
        switch status {
        case .missing:
            return String(
                format: String(localized: "Nothing is at %@. Start the server, or check the folder and the port."),
                file
            )
        case .notSocket:
            return String(format: String(localized: "%@ is not a socket."), file)
        case .socket, .none:
            return String(
                format: String(localized: "Connects to %@. The port names the socket file in the folder."),
                file
            )
        }
    }
}
