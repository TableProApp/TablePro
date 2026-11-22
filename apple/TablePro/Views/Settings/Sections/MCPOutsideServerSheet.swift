import AppKit
import SwiftUI
import TableProMCP

// The allowlist sits beside the address: a server allowed on no connection does nothing. Nothing is written until Save.
internal struct MCPOutsideServerSheet: View {
    internal let server: MCPServerConfiguration?

    private enum TestState: Equatable {
        case idle
        case running
        case succeeded(toolCount: Int)
        case failed(message: String)
    }

    @Environment(\.dismiss) private var dismiss

    @State private var newServerId = UUID()
    @State private var name = ""
    @State private var endpointText = ""
    @State private var token = ""
    @State private var allowedConnectionIds: Set<UUID> = []
    @State private var saveError: MCPServerSaveError?
    @State private var testState: TestState = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var connections: [DatabaseConnection] = []
    @State private var hasLoaded = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                serverSection
                allowedOnSection
            }
            .formStyle(.grouped)

            Divider()

            footer
                .padding()
        }
        .frame(width: 520, height: Self.height)
        .onAppear(perform: load)
        .onDisappear {
            testTask?.cancel()
        }
        .onChange(of: name) { _ in resetFeedback() }
        .onChange(of: endpointText) { _ in resetFeedback() }
        .onChange(of: token) { _ in resetFeedback() }
        .alert(String(localized: "Remove Server?"), isPresented: $isConfirmingRemoval) {
            Button(String(localized: "Remove"), role: .destructive, action: remove)
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(
                format: String(localized: "“%@” and its token are removed from this Mac. Sessions lose its tools."),
                server?.name ?? ""
            ))
        }
    }

    private static var height: CGFloat {
        min(560, (NSScreen.main?.visibleFrame.height ?? 640) - 80)
    }

    private var serverSection: some View {
        Section {
            TextField(text: $name, prompt: nil) {
                Text("Name")
                if let nameError {
                    NoticeLabel(nameError, severity: .error)
                }
            }
            .accessibilityIdentifier("mcp-outside-server-name")

            TextField(text: $endpointText, prompt: Text(verbatim: "https://example.com/mcp")) {
                Text("Address")
                if let addressError {
                    NoticeLabel(addressError, severity: .error)
                }
            }
            .autocorrectionDisabled()
            .accessibilityIdentifier("mcp-outside-server-address")

            SecureField(text: $token, prompt: tokenPrompt) {
                Text("Token")
                if let tokenError {
                    NoticeLabel(tokenError, severity: .error)
                }
            }
            .accessibilityIdentifier("mcp-outside-server-token")

            LabeledContent {
                HStack(spacing: 8) {
                    DelayedProgressIndicator(isActive: testState == .running)
                        .accessibilityHidden(true)
                    Button(String(localized: "Test"), action: runTest)
                        .disabled(testState == .running || !canTest)
                        .accessibilityIdentifier("mcp-outside-server-test")
                }
            } label: {
                Text("Connection test")
                testResult
            }

            SettingsHelpRow("The address has to be HTTPS unless the server runs on this Mac. The token is kept in your Keychain and never synced.")
        } header: {
            Text("Server")
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .running:
            Text("Testing…")
        case .succeeded(let toolCount):
            Text("Answered with ^[\(toolCount) tool](inflect: true).")
        case .failed(let message):
            NoticeLabel(message, severity: .error)
        }
    }

    private var allowedOnSection: some View {
        Section {
            ConnectionAllowlistSection(
                selection: $allowedConnectionIds,
                connections: connections,
                showsSelectAll: false
            )

            // swiftlint:disable:next line_length
            SettingsHelpRow("A session can call this server's tools only from a connection you tick. It is offered on no others, and a tool it once saw cannot be called by name from one.")
        } header: {
            Text("Allowed On")
        }
    }

    private var footer: some View {
        DialogFooter {
            if server != nil {
                Button(String(localized: "Remove Server…"), role: .destructive) {
                    isConfirmingRemoval = true
                }
                .accessibilityIdentifier("mcp-outside-server-remove")
            }
        } actions: {
            Button(String(localized: "Cancel"), role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "Save"), action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityIdentifier("mcp-outside-server-save")
        }
    }

    // The saved token is never read back into the field, so it cannot end up in a screenshot.
    private var tokenPrompt: Text {
        keepsSavedToken
            ? Text("Leave blank to keep the saved token")
            : Text("Required")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEndpoint: String {
        endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var typedEndpoint: URL? {
        trimmedEndpoint.isEmpty ? nil : URL(string: trimmedEndpoint)
    }

    // The saved token goes only where it was saved for: the same scheme, host and port.
    private var keepsSavedToken: Bool {
        guard let server, let typedEndpoint else { return false }
        return MCPServerStore.sharesOrigin(server.endpoint, typedEndpoint)
    }

    private var canTest: Bool {
        !trimmedEndpoint.isEmpty && (!token.isEmpty || keepsSavedToken)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !trimmedEndpoint.isEmpty && (!token.isEmpty || keepsSavedToken)
    }

    private var nameError: String? {
        guard case .invalid(let error)? = saveError else { return nil }
        switch error {
        case .emptyName:
            return String(localized: "Give the server a name.")
        case .reservedName:
            return String(localized: "That name belongs to TablePro's own tools. Choose another.")
        case .invalidEndpoint, .insecureEndpoint, .credentialsInEndpoint:
            return nil
        }
    }

    private var addressError: String? {
        guard case .invalid(let error)? = saveError else { return nil }
        switch error {
        case .invalidEndpoint:
            return String(localized: "That is not an HTTP address.")
        case .insecureEndpoint:
            return String(localized: "A server on another machine has to be HTTPS.")
        case .credentialsInEndpoint:
            return String(localized: "Put the credential in the Token field, not in the address.")
        case .emptyName, .reservedName:
            return nil
        }
    }

    private var tokenError: String? {
        switch saveError {
        case .tokenRequired?:
            return String(localized: "Type the server's token. A saved token stays with the address it was saved for.")
        case .tokenNotSaved?:
            return String(localized: "TablePro could not save the token to the Keychain, so the server was not saved. Try again.")
        case .invalid?, nil:
            return nil
        }
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        connections = ConnectionStorage.shared.loadConnections()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let server else { return }
        name = server.name
        endpointText = server.endpoint.absoluteString
        allowedConnectionIds = server.allowedConnectionIds
    }

    private func resetFeedback() {
        testTask?.cancel()
        testTask = nil
        testState = .idle
        saveError = nil
    }

    private func draft() -> MCPServerConfiguration? {
        guard let typedEndpoint else { return nil }
        return MCPServerConfiguration(
            id: server?.id ?? newServerId,
            name: trimmedName,
            endpoint: typedEndpoint,
            allowedConnectionIds: allowedConnectionIds
        )
    }

    private func runTest() {
        guard let configuration = draft() else {
            saveError = .invalid(.invalidEndpoint)
            return
        }
        if let error = MCPServerConfigurationValidator.validate(
            name: configuration.name,
            endpoint: configuration.endpoint
        ) {
            saveError = .invalid(error)
            return
        }
        guard let probeToken = probeToken() else {
            testState = .failed(message: String(localized: "TablePro could not read the saved token. Type it to test."))
            return
        }
        saveError = nil
        testState = .running
        testTask?.cancel()
        testTask = Task {
            let result = await MCPRemoteToolCoordinator.shared.probe(configuration, token: probeToken)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let tools):
                testState = .succeeded(toolCount: tools.count)
            case .failure(let error):
                testState = .failed(message: error.localizedMessage)
            }
        }
    }

    // Read at the click, never in the body: the typed token first, else the saved one for the saved origin.
    private func probeToken() -> String? {
        if !token.isEmpty { return token }
        guard keepsSavedToken, let server else { return nil }
        return MCPServerStore.shared.token(for: server.id)
    }

    private func save() {
        guard canSave else { return }
        guard let configuration = draft() else {
            saveError = .invalid(.invalidEndpoint)
            return
        }
        if let error = MCPServerStore.shared.upsert(configuration, token: token.isEmpty ? nil : token) {
            saveError = error
            return
        }
        dismiss()
    }

    private func remove() {
        guard let server else { return }
        MCPServerStore.shared.remove(id: server.id)
        dismiss()
    }
}
