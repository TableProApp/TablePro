import AppKit
import SwiftUI

struct MCPTokenRevealSheet: View {
    let token: MCPAuthToken
    let plaintext: String
    let port: Int
    let allowRemoteConnections: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var isTokenRevealed = false
    @State private var tokenCopied = false
    @State private var selectedClient: IntegrationClient = .claudeCode

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
        Label {
            Text(String(localized: "This token will not be shown again"))
                .fontWeight(.medium)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .systemOrange), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                tokenCopied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    tokenCopied = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tokenCopied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                    Text(tokenCopied
                        ? String(localized: "Copied")
                        : String(localized: "Copy Token"))
                }
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

            CopyableCodeBlock(text: configSnippet(for: selectedClient))
        }
    }

    private var baseURL: String {
        let scheme = allowRemoteConnections ? "https" : "http"
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
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
