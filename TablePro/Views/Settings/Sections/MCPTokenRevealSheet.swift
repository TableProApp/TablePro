//
//  MCPTokenRevealSheet.swift
//  TablePro
//

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
    @State private var selectedClient: MCPSetupClient = .claudeCode

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
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 540, height: 520)
    }

    // MARK: - Warning Banner

    private var warningBanner: some View {
        Label {
            Text("This token will not be shown again")
                .fontWeight(.medium)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Token Display

    private var tokenDisplay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token")
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
                .help(isTokenRevealed ? String(localized: "Hide token") : String(localized: "Reveal token"))
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
                    Text(tokenCopied ? "Copied" : "Copy Token")
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var maskedToken: String {
        String(plaintext.prefix(8)) + String(repeating: "\u{2022}", count: 24)
    }

    // MARK: - Setup Instructions

    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup Instructions")
                .font(.headline)

            Picker("Client", selection: $selectedClient) {
                ForEach(MCPSetupClient.allCases) { client in
                    Text(client.displayName).tag(client)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            snippetView(for: selectedClient)
        }
    }

    @ViewBuilder
    private func snippetView(for client: MCPSetupClient) -> some View {
        let snippet = configSnippet(for: client)
        MCPCopyableCodeBlock(text: snippet)
    }

    // MARK: - Config Snippets

    private var baseURL: String {
        let scheme = allowRemoteConnections ? "https" : "http"
        return "\(scheme)://127.0.0.1:\(port)/mcp"
    }

    private func configSnippet(for client: MCPSetupClient) -> String {
        switch client {
        case .claudeCode:
            return "claude mcp add tablepro --transport http \(baseURL) --header \"Authorization: Bearer \(plaintext)\""
        case .claudeDesktop:
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
        case .cursor:
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

// MARK: - Setup Client

private enum MCPSetupClient: String, CaseIterable, Identifiable {
    case claudeCode
    case claudeDesktop
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .cursor: "Cursor"
        }
    }
}

// MARK: - Copyable Code Block

private struct MCPCopyableCodeBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(String(localized: "Copy to clipboard"))
        }
    }
}
