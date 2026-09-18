//
//  MCPOutsideServerSheet.swift
//  TablePro
//

import SwiftUI

/// Adds or edits one outside MCP server, and says which connections may reach it.
///
/// The allowlist is in the same sheet as the address rather than behind a second screen, because a
/// server with no connections allowed does nothing and a reader who does not see the list has no
/// reason to look for it. Nothing is written until Save: Test uses the token typed into the field,
/// so checking an address you got wrong does not leave a server in the list you never meant to add.
internal struct MCPOutsideServerSheet: View {
    internal let server: MCPServerConfiguration?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MCPServerStore.shared

    @State private var name = ""
    @State private var endpointText = ""
    @State private var token = ""
    @State private var allowedConnectionIds: Set<UUID> = []
    @State private var validationError: MCPServerConfigurationError?
    @State private var testState: TestState = .idle
    @State private var connections: [DatabaseConnection] = []

    private enum TestState: Equatable {
        case idle
        case running
        case succeeded(toolCount: Int)
        case failed(message: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                serverSection
                connectionsSection
            }
            .formStyle(.grouped)

            Divider()
            buttonBar
        }
        .frame(width: 520, height: 520)
        .onAppear(perform: load)
    }

    private var serverSection: some View {
        Section {
            TextField(String(localized: "Name"), text: $name)
            TextField(String(localized: "Address"), text: $endpointText, prompt: Text(verbatim: "https://example.com/mcp"))
                .autocorrectionDisabled()
            SecureField(String(localized: "Token"), text: $token, prompt: tokenPrompt)

            HStack(spacing: 8) {
                Button(String(localized: "Test"), action: runTest)
                    .disabled(testState == .running || token.isEmpty)
                DelayedProgressIndicator(isActive: testState == .running)
                testResult
                Spacer(minLength: 0)
            }
        } header: {
            Text("Server")
        } footer: {
            if let validationError {
                Text(message(for: validationError))
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("The address has to be HTTPS unless the server runs on this Mac. The token is kept in your Keychain and never synced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle, .running:
            EmptyView()
        case .succeeded(let toolCount):
            Text(toolCount == 1
                ? String(localized: "Answered with 1 tool.")
                : String(format: String(localized: "Answered with %d tools."), toolCount))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var connectionsSection: some View {
        Section {
            if connections.isEmpty {
                Text("No connections saved yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(connections) { connection in
                    Toggle(connection.name, isOn: binding(for: connection.id))
                }
            }
        } header: {
            Text("Allowed On")
        } footer: {
            Text("A session can call this server's tools only from a connection you tick. It is offered on no others, and a tool it once saw cannot be called by name from one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Save"), action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpointText.isEmpty)
        }
        .padding(16)
    }

    /// An existing server's token is not read back into the field. The Keychain has it, the sheet
    /// does not need it, and putting a live credential into a text field so it can be typed over is
    /// how one ends up in a screenshot.
    private var tokenPrompt: Text {
        server == nil
            ? Text(String(localized: "Required"))
            : Text(String(localized: "Leave blank to keep the saved token"))
    }

    private func load() {
        connections = ConnectionStorage.shared.loadConnections()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let server else { return }
        name = server.name
        endpointText = server.endpoint.absoluteString
        allowedConnectionIds = server.allowedConnectionIds
    }

    private func binding(for connectionId: UUID) -> Binding<Bool> {
        Binding(
            get: { allowedConnectionIds.contains(connectionId) },
            set: { isOn in
                if isOn {
                    allowedConnectionIds.insert(connectionId)
                } else {
                    allowedConnectionIds.remove(connectionId)
                }
            }
        )
    }

    private func draft() -> MCPServerConfiguration {
        MCPServerConfiguration(
            id: server?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? URL(fileURLWithPath: "/"),
            allowedConnectionIds: allowedConnectionIds
        )
    }

    private func runTest() {
        let configuration = draft()
        if let error = MCPServerConfigurationValidator.validate(
            name: configuration.name,
            endpoint: URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines))
        ) {
            validationError = error
            testState = .idle
            return
        }
        validationError = nil
        testState = .running
        let probeToken = token
        Task { @MainActor in
            let result = await MCPRemoteToolCoordinator.shared.probe(configuration, token: probeToken)
            switch result {
            case .success(let tools):
                testState = .succeeded(toolCount: tools.count)
            case .failure(let error):
                testState = .failed(message: error.localizedMessage)
            }
        }
    }

    private func save() {
        let configuration = draft()
        if let error = store.upsert(configuration, token: token.isEmpty ? nil : token) {
            validationError = error
            return
        }
        dismiss()
    }

    private func message(for error: MCPServerConfigurationError) -> String {
        switch error {
        case .emptyName:
            String(localized: "Give the server a name.")
        case .reservedName:
            String(localized: "That name belongs to TablePro's own tools. Choose another.")
        case .invalidEndpoint:
            String(localized: "That is not an HTTP address.")
        case .insecureEndpoint:
            String(localized: "A server on another machine has to be HTTPS.")
        case .credentialsInEndpoint:
            String(localized: "Put the credential in the Token field, not in the address.")
        }
    }
}
