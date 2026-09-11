//
//  MCPOutsideServersSection.swift
//  TablePro
//

import SwiftUI

/// Servers TablePro calls, as opposed to the one it runs.
///
/// The two directions live in one pane because a reader looking for "MCP" does not know which of
/// them they need, and the sentence about what leaves the machine belongs next to the list of places
/// it can go.
internal struct MCPOutsideServersSection: View {
    private let store = MCPServerStore.shared

    @State private var name: String = ""
    @State private var endpoint: String = ""
    @State private var token: String = ""
    @State private var error: MCPServerConfigurationError?
    @State private var probeResult: String?
    @State private var isProbing = false
    @State private var pendingRemoval: MCPServerConfiguration?

    internal var body: some View {
        Section(String(localized: "Outside MCP Servers")) {
            Text(String(localized: """
                A session can call these servers as tools. Whatever the assistant hands one, \
                including schema and query results, leaves this Mac.
                """))
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(store.servers) { server in
                serverRow(server)
            }

            if store.servers.isEmpty {
                Text(String(localized: "No servers added."))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }

        Section(String(localized: "Add a Server")) {
            TextField(String(localized: "Name"), text: $name)
            TextField(String(localized: "Endpoint"), text: $endpoint, prompt: Text(verbatim: "https://example.com/mcp"))
            SecureField(String(localized: "Bearer token"), text: $token)

            if let error {
                Text(Self.message(for: error))
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if let probeResult {
                Text(probeResult)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            /// Add wants the token too. A server stored without one is inert: every call builds its
            /// session through `MCPClientSession.make`, which refuses to reach a configured endpoint
            /// with no credential, so adding one without a token produced an entry that could be
            /// ticked onto a connection and would never answer.
            HStack(spacing: 8) {
                Button(String(localized: "Add")) { add() }
                    .disabled(isProbing || name.isEmpty || endpoint.isEmpty || token.isEmpty)
                Button(String(localized: "Test")) { Task { await test() } }
                    .disabled(isProbing || endpoint.isEmpty || token.isEmpty)
                if isProbing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }

        Section {
            Text(String(localized: """
                A tool from an outside server always waits for your approval, in every chat mode, \
                and every call is recorded in the audit log with the size of what was sent.
                """))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            pendingRemoval.map {
                String(format: String(localized: "Remove %@?"), $0.name)
            } ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { server in
            Button(String(localized: "Remove"), role: .destructive) {
                store.remove(id: server.id)
                pendingRemoval = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text(String(localized: """
                Its bearer token is deleted from the Keychain and every connection allowed to reach \
                it loses that permission. This cannot be undone.
                """))
        }
    }

    /// Remove is a push button, not a link, and it asks first.
    ///
    /// It drops the server's bearer token from the Keychain and its allowlist along with it, none of
    /// which comes back, and `.link` gave a destructive command the styling of a navigation one and
    /// swallowed the `.destructive` role's own treatment.
    private func serverRow(_ server: MCPServerConfiguration) -> some View {
        LabeledContent {
            Button(String(localized: "Remove"), role: .destructive) {
                pendingRemoval = server
            }
            .buttonStyle(.borderless)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text(verbatim: server.endpoint.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    server.allowedConnectionIds.isEmpty
                        ? String(localized: "Not allowed on any connection yet")
                        : String(
                            format: String(localized: "Allowed on %d connections"),
                            server.allowedConnectionIds.count
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func draft() -> MCPServerConfiguration? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return MCPServerConfiguration(name: name.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: url)
    }

    private func add() {
        probeResult = nil
        guard let configuration = draft() else {
            error = .invalidEndpoint
            return
        }
        error = store.upsert(configuration, token: token)
        guard error == nil else { return }
        name = ""
        endpoint = ""
        token = ""
    }

    /// Test adds nothing. It builds a throwaway session against what is typed in the fields and
    /// throws it away again, so checking an endpoint is a question rather than a commitment. It used
    /// to write the server and its credential first and then probe what it had written, which left a
    /// reader who mistyped a URL with a server in their list they never asked to add.
    ///
    /// The name is still validated, because Test reports on a configuration and a configuration with
    /// a reserved name is one the user cannot keep.
    private func test() async {
        probeResult = nil
        guard let configuration = draft() else {
            error = .invalidEndpoint
            return
        }
        if let invalid = MCPServerConfigurationValidator.validate(name: name, endpoint: configuration.endpoint) {
            error = invalid
            return
        }
        error = nil
        isProbing = true
        defer { isProbing = false }
        switch await MCPRemoteToolCoordinator.shared.probe(configuration, token: token) {
        case .success(let tools):
            probeResult = String(
                format: String(localized: "Answered with %d tools."),
                tools.count
            )
        case .failure(let failure):
            probeResult = failure.localizedMessage
        }
    }

    private static func message(for error: MCPServerConfigurationError) -> String {
        switch error {
        case .emptyName:
            return String(localized: "Give the server a name.")
        case .reservedName:
            return String(localized: "That name is reserved for TablePro's own MCP server. Pick another.")
        case .invalidEndpoint:
            return String(localized: "The endpoint must be an http or https URL with a host.")
        case .insecureEndpoint:
            return String(localized: "Plain http is only allowed for a server on this Mac. Use https.")
        }
    }
}
