import AppKit
import SwiftUI

struct MCPTokenRevealSheet: View {
    let plaintext: String
    let port: Int
    let configuredPort: Int
    @Environment(\.dismiss) private var dismiss

    @State private var isTokenRevealed = false
    @State private var selectedClientID: String

    private let setup: MCPHTTPClientSetup

    init(plaintext: String, port: Int, configuredPort: Int) {
        self.plaintext = plaintext
        self.port = port
        self.configuredPort = configuredPort
        let setup = MCPHTTPClientSetup(port: port)
        self.setup = setup
        _selectedClientID = State(initialValue: setup.choices.first?.id ?? MCPHTTPClientSetup.otherClientID)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    warningBanner
                    tokenDisplay
                    setupInstructions
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 540, minHeight: 520)
    }

    private var warningBanner: some View {
        NoticeLabel(String(localized: "This token will not be shown again"), severity: .warning)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tokenDisplay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Token"))
                .font(.headline)

            HStack(spacing: 8) {
                Text(verbatim: displayedToken)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Button {
                    isTokenRevealed.toggle()
                } label: {
                    Image(systemName: isTokenRevealed ? "eye.slash" : "eye")
                }
                .accessibilityLabel(isTokenRevealed
                    ? String(localized: "Hide token")
                    : String(localized: "Reveal token"))
                .help(isTokenRevealed
                    ? String(localized: "Hide token")
                    : String(localized: "Reveal token"))
            }
            .padding(10)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button {
                ClipboardService.shared.writeSecretText(plaintext)
                AccessibilityAnnouncement.post(String(localized: "Copied to clipboard"))
            } label: {
                Label(String(localized: "Copy Token"), systemImage: "doc.on.doc")
            }
            .accessibilityLabel(String(localized: "Copy token"))
        }
    }

    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Setup Instructions"))
                .font(.headline)

            Picker(String(localized: "Client"), selection: $selectedClientID) {
                ForEach(setup.choices) { choice in
                    Text(verbatim: choice.name).tag(choice.id)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("mcp-token-client-picker")

            if port != configuredPort {
                NoticeLabel(String(
                    format: String(localized: "Port %d was in use, so this address changes when TablePro restarts."),
                    configuredPort
                ))
            }

            if selectedClientID == MCPHTTPClientSetup.otherClientID {
                otherClientInstructions
            } else {
                clientInstructions
            }
        }
    }

    @ViewBuilder
    private var clientInstructions: some View {
        if let copied = setup.render(clientID: selectedClientID, token: plaintext),
           let shown = setup.render(clientID: selectedClientID, token: displayedToken) {
            if let commandLine = copied.commandLine {
                Text(String(localized: "Run this in Terminal:"))
                CopyableCodeBlock(text: commandLine, displayText: shown.commandLine, isSecret: true)
            }
            if let snippet = copied.snippet {
                if let path = copied.displayConfigPath {
                    Text(String(format: String(localized: "Add this to %@:"), path))
                }
                CopyableCodeBlock(text: snippet, displayText: shown.snippet, isSecret: true)
            }
        } else {
            otherClientInstructions
        }
    }

    private var otherClientInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Give your client this address and header:"))
            CopyableCodeBlock(text: setup.url)
            CopyableCodeBlock(
                text: header(token: plaintext),
                displayText: header(token: displayedToken),
                isSecret: true
            )
        }
    }

    private func header(token: String) -> String {
        "Authorization: " + MCPHTTPClientSetup.authorization(token: token)
    }

    private var displayedToken: String {
        isTokenRevealed ? plaintext : maskedToken
    }

    private var maskedToken: String {
        String(plaintext.prefix(8)) + String(repeating: "\u{2022}", count: 24)
    }
}
