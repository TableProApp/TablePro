import SwiftUI

struct MCPTokenCreateFailure: Error, Equatable, Sendable {
    let message: String
    // Nothing in this sheet can fix a server that is not running, so the alert closes it.
    let endsSheet: Bool
}

struct MCPTokenRequest: Equatable, Sendable {
    let name: String
    let permissions: TokenPermissions
    let connectionIds: Set<UUID>?
    let expiresAt: Date?
}

struct MCPTokenReveal: Sendable {
    let plaintext: String
    let setup: MCPHTTPClientSetup
    let port: Int
    let configuredPort: Int
}

// One sheet, the form and then the token, so the plaintext lives only in this sheet's state and goes with it.
struct MCPTokenCreateSheet: View {
    private enum Field: Hashable {
        case name
    }

    private enum Access: Hashable {
        case all
        case selected
    }

    @Environment(\.dismiss) private var dismiss
    let onGenerate: (MCPTokenRequest) async -> Result<MCPTokenReveal, MCPTokenCreateFailure>

    @State private var name = ""
    @State private var permissions: TokenPermissions = .readOnly
    @State private var access: Access = .all
    @State private var selectedConnectionIds: Set<UUID> = []
    @State private var expiry: TokenExpiry = .never
    @State private var customExpiry = TokenExpiry.defaultCustomDate()
    @State private var connections: [DatabaseConnection] = []
    @State private var isGenerating = false
    @State private var failure: MCPTokenCreateFailure?
    @State private var reveal: MCPTokenReveal?
    @FocusState private var focused: Field?

    var body: some View {
        Group {
            if let reveal {
                MCPTokenRevealSheet(reveal: reveal) {
                    dismiss()
                }
            } else {
                createForm
            }
        }
        .frame(minWidth: 540, minHeight: 520)
    }

    private var createForm: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(text: $name, prompt: Text("Cursor on my Mac")) {
                        Text("Name")
                    }
                    .focused($focused, equals: .name)
                    .accessibilityIdentifier("mcp-token-name-field")

                    Picker(selection: $permissions) {
                        ForEach(TokenPermissions.allCases) { permission in
                            Text(permission.displayName).tag(permission)
                        }
                    } label: {
                        Text("Permissions")
                        Text(permissions.summary)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("mcp-token-permissions-picker")
                }

                Section {
                    Picker(selection: $access) {
                        Text("All").tag(Access.all)
                        Text("Selected").tag(Access.selected)
                    } label: {
                        Text("Connections")
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("mcp-token-connections-picker")

                    if access == .selected {
                        ConnectionAllowlistSection(
                            selection: $selectedConnectionIds,
                            connections: connections,
                            showsSelectAll: true
                        )
                    }
                }

                Section {
                    Picker(selection: $expiry) {
                        ForEach(TokenExpiry.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    } label: {
                        Text("Expires")
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("mcp-token-expiry-picker")

                    if expiry == .custom {
                        DatePicker(
                            String(localized: "Expiration date"),
                            selection: $customExpiry,
                            in: Date.now...,
                            displayedComponents: .date
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .defaultFocus($focused, .name)

            Divider()

            DialogFooter {
                Button(String(localized: "Cancel"), role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Generate"), action: generate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canGenerate)
                    .accessibilityIdentifier("mcp-token-generate")
            }
            .padding()
        }
        .task {
            connections = ConnectionStorage.shared.loadConnections()
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        .alert(
            String(localized: "Couldn't Create the Token"),
            isPresented: failureBinding,
            presenting: failure
        ) { failure in
            Button(String(localized: "OK")) {
                self.failure = nil
                if failure.endsSheet {
                    dismiss()
                }
            }
        } message: { failure in
            Text(verbatim: failure.message)
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canGenerate: Bool {
        !isGenerating && !trimmedName.isEmpty && !(access == .selected && selectedConnectionIds.isEmpty)
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { failure != nil },
            set: { isPresented in
                if !isPresented {
                    failure = nil
                }
            }
        )
    }

    private func generate() {
        guard canGenerate else { return }
        let request = MCPTokenRequest(
            name: trimmedName,
            permissions: permissions,
            connectionIds: access == .selected ? selectedConnectionIds : nil,
            expiresAt: expiry.resolvedDate(custom: customExpiry)
        )
        isGenerating = true
        Task {
            let result = await onGenerate(request)
            isGenerating = false
            switch result {
            case .success(let issued):
                reveal = issued
            case .failure(let failed):
                failure = failed
            }
        }
    }
}
