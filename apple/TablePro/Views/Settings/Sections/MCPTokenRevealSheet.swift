import AppKit
import SwiftUI

struct MCPTokenRevealSheet: View {
    let token: MCPAuthToken
    let plaintext: String
    let port: Int
    @Environment(\.dismiss) private var dismiss

    @State private var isTokenRevealed = false
    @State private var selectedClient: IntegrationClient = .claudeCode
    @FocusState private var doneFocused: Bool

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
                    .focused($doneFocused)
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
                Text(isTokenRevealed ? plaintext : maskedToken)
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
                copyToClipboard(plaintext)
            } label: {
                Label(String(localized: "Copy Token"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(String(localized: "Copy token"))
        }
    }

    private var maskedToken: String {
        String(plaintext.prefix(8)) + String(repeating: "\u{2022}", count: 24)
    }

    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Setup Instructions"))
                .font(.headline)

            Picker(String(localized: "Client"), selection: $selectedClient) {
                ForEach(IntegrationClient.allCases) { client in
                    Text(client.displayName).tag(client)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            CopyableCodeBlock(text: configSnippet(for: selectedClient), isSecret: true)
        }
    }

    private var baseURL: String {
        let scheme = "http"
        return "\(scheme)://127.0.0.1:\(port)/mcp"
    }

    private func configSnippet(for client: IntegrationClient) -> String {
        switch client {
        case .claudeCode:
            return "claude mcp add tablepro --transport http \(baseURL) --header \"Authorization: Bearer \(plaintext)\""
        case .claudeDesktop, .cursor:
            return """
            {
              "mcpServers": {
                "tablepro": {
                  "url": "\(baseURL)",
                  "headers": {
                    "Authorization": "Bearer \(plaintext)"
                  }
                }
              }
            }
            """
        case .zed:
            return """
            {
              "tablepro": {
                "url": "\(baseURL)",
                "headers": {
                  "Authorization": "Bearer \(plaintext)"
                }
              }
            }
            """
        }
    }

    private func copyToClipboard(_ text: String) {
        ClipboardService.shared.writeSecretText(text)
        AccessibilityAnnouncement.post(String(localized: "Copied to clipboard"))
    }
}
