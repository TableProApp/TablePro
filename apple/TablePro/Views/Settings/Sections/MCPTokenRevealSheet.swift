import SwiftUI

// Shown inside MCPTokenCreateSheet once the token exists; it has no cancel action, only Done.
struct MCPTokenRevealSheet: View {
    let reveal: MCPTokenReveal
    let onDone: () -> Void

    @State private var isTokenRevealed = false
    @State private var selectedClientID: String

    init(reveal: MCPTokenReveal, onDone: @escaping () -> Void) {
        self.reveal = reveal
        self.onDone = onDone
        _selectedClientID = State(initialValue: reveal.setup.choices.first?.id ?? MCPHTTPClientSetup.otherClientID)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    NoticeLabel(String(localized: "Copy this token now. TablePro won't show it again."), severity: .warning)

                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(verbatim: displayedToken)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Button {
                                isTokenRevealed.toggle()
                            } label: {
                                Image(systemName: isTokenRevealed ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(isTokenRevealed
                                ? String(localized: "Hide token")
                                : String(localized: "Reveal token"))
                            .help(isTokenRevealed
                                ? String(localized: "Hide token")
                                : String(localized: "Reveal token"))

                            Button(String(localized: "Copy")) {
                                ClipboardService.shared.writeSecretText(reveal.plaintext)
                                AccessibilityAnnouncement.post(String(localized: "Copied to clipboard"))
                            }
                            .accessibilityLabel(String(localized: "Copy token"))
                            .accessibilityIdentifier("mcp-token-copy")
                        }
                    } label: {
                        Text("Token")
                    }
                }

                Section {
                    Picker(String(localized: "Client"), selection: $selectedClientID) {
                        ForEach(reveal.setup.choices) { choice in
                            Text(verbatim: choice.name).tag(choice.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("mcp-token-client-picker")

                    if reveal.port != reveal.configuredPort {
                        NoticeLabel(String(
                            format: String(localized: "Port %d was in use, so this address changes when TablePro restarts."),
                            reveal.configuredPort
                        ))
                    }

                    if selectedClientID == MCPHTTPClientSetup.otherClientID {
                        otherClientInstructions
                    } else {
                        clientInstructions
                    }
                } header: {
                    Text("Set Up a Client")
                }
            }
            .formStyle(.grouped)

            Divider()

            DialogFooter {
                Button(String(localized: "Done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("mcp-token-done")
            }
            .padding()
        }
    }

    @ViewBuilder
    private var clientInstructions: some View {
        if let copied = reveal.setup.render(clientID: selectedClientID, token: reveal.plaintext),
           let shown = reveal.setup.render(clientID: selectedClientID, token: displayedToken) {
            if let commandLine = copied.commandLine {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run this in Terminal:")
                    CopyableCodeBlock(text: commandLine, displayText: shown.commandLine, isSecret: true)
                }
            }
            if let snippet = copied.snippet {
                VStack(alignment: .leading, spacing: 6) {
                    if let path = copied.displayConfigPath {
                        Text(String(format: String(localized: "Add this to %@:"), path))
                    }
                    CopyableCodeBlock(text: snippet, displayText: shown.snippet, isSecret: true)
                }
            }
        } else {
            otherClientInstructions
        }
    }

    private var otherClientInstructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Give your client this address and header:")
            CopyableCodeBlock(text: reveal.setup.url)
            CopyableCodeBlock(
                text: header(token: reveal.plaintext),
                displayText: header(token: displayedToken),
                isSecret: true
            )
        }
    }

    private func header(token: String) -> String {
        "Authorization: " + MCPHTTPClientSetup.authorization(token: token)
    }

    private var displayedToken: String {
        isTokenRevealed ? reveal.plaintext : maskedToken
    }

    private var maskedToken: String {
        String(reveal.plaintext.prefix(8)) + String(repeating: "\u{2022}", count: 24)
    }
}
