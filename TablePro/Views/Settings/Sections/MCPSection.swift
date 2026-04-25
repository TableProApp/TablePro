//
//  MCPSection.swift
//  TablePro
//

import AppKit
import SwiftUI

struct MCPSection: View {
    @Binding var settings: MCPSettings
    @State private var manager = MCPServerManager.shared
    @State private var selectedTool: MCPClientTool = .claudeDesktop
    @State private var tokenList: [MCPAuthToken] = []
    @State private var showCreateSheet = false
    @State private var showRevealSheet = false
    @State private var revealedToken: MCPAuthToken?
    @State private var revealedPlaintext: String = ""

    var body: some View {
        Section("MCP Server") {
            Toggle("Enable MCP Server", isOn: $settings.enabled)

            if settings.enabled {
                LabeledContent("Status") {
                    MCPStatusIndicator()
                }
            }
        }

        if settings.enabled {
            configurationSection
            authenticationSection
            networkSection
            setupSection
            connectedClientsSection

            Section {
                Text("AI access policies are configured per-connection in each connection's settings.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        Section("MCP Configuration") {
            LabeledContent("Port") {
                TextField("", value: $settings.port, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("Default row limit") {
                TextField("", value: $settings.defaultRowLimit, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("Maximum row limit") {
                TextField("", value: $settings.maxRowLimit, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("Query timeout") {
                HStack(spacing: 4) {
                    TextField("", value: $settings.queryTimeoutSeconds, format: .number.grouping(.never))
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Log MCP queries in history", isOn: $settings.logQueriesInHistory)
        }
    }

    // MARK: - Authentication

    private var authenticationSection: some View {
        Section("Authentication") {
            Toggle("Require authentication", isOn: $settings.requireAuthentication)

            if settings.requireAuthentication {
                MCPTokenListView(
                    tokens: tokenList,
                    onGenerate: { showCreateSheet = true },
                    onRevoke: { id in Task { await manager.tokenStore?.revoke(tokenId: id); await refreshTokens() } },
                    onDelete: { id in Task { await manager.tokenStore?.delete(tokenId: id); await refreshTokens() } }
                )
            }
        }
        .task { await refreshTokens() }
        .sheet(isPresented: $showCreateSheet) {
            MCPTokenCreateSheet(onGenerate: handleGenerate)
        }
        .sheet(isPresented: $showRevealSheet) {
            if let revealedToken {
                MCPTokenRevealSheet(
                    token: revealedToken,
                    plaintext: revealedPlaintext,
                    port: settings.port,
                    allowRemoteConnections: settings.allowRemoteConnections
                )
            }
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Section("Network") {
            Toggle("Allow remote connections", isOn: $settings.allowRemoteConnections)

            if settings.allowRemoteConnections {
                Label {
                    Text("The server will be accessible from other devices on your network. Authentication and TLS are enabled automatically.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
            }
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section("MCP Setup") {
            Picker("Client:", selection: $selectedTool) {
                ForEach(MCPClientTool.allCases) { tool in
                    Text(tool.displayName).tag(tool)
                }
            }

            MCPSetupInstructions(tool: selectedTool, port: settings.port)
        }
    }

    // MARK: - Connected Clients

    private var connectedClientsSection: some View {
        Section("Connected Clients") {
            if manager.connectedClients.isEmpty {
                Text("No clients connected")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.connectedClients) { client in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(client.clientName)
                                if let version = client.clientVersion {
                                    Text(version)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(client.connectedSince, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Disconnect") {
                            Task { await manager.disconnectClient(client.id) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Token Management

    private func handleGenerate(name: String, permissions: TokenPermissions, connectionIds: Set<UUID>?, expiresAt: Date?) {
        Task {
            guard let store = manager.tokenStore else { return }
            let result = await store.generate(
                name: name,
                permissions: permissions,
                allowedConnectionIds: connectionIds,
                expiresAt: expiresAt
            )
            revealedToken = result.token
            revealedPlaintext = result.plaintext
            showCreateSheet = false
            showRevealSheet = true
            await refreshTokens()
        }
    }

    private func refreshTokens() async {
        guard let store = MCPServerManager.shared.tokenStore else { return }
        tokenList = await store.list().filter { $0.name != "__stdio_bridge__" }
    }
}

// MARK: - MCP Client Tool

private enum MCPClientTool: String, CaseIterable, Identifiable {
    case claudeDesktop, claudeCode, cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        }
    }
}

// MARK: - Setup Instructions

private struct MCPSetupInstructions: View {
    let tool: MCPClientTool
    let port: Int
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 20, alignment: .trailing)
                    Text(step)
                        .textSelection(.enabled)
                }
            }

            if let snippet = configSnippet {
                copyableCodeBlock(snippet)
            }
            if let command {
                copyableCodeBlock(command)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func copyableCodeBlock(_ text: String) -> some View {
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

    private var url: String { "http://127.0.0.1:\(port)/mcp" }

    private var steps: [String] {
        switch tool {
        case .claudeDesktop:
            [
                "Open Claude Desktop, go to Settings > Developer",
                "Click \"Edit Config\" to open claude_desktop_config.json",
                "Add the JSON below inside the file and save",
                "Restart Claude Desktop"
            ]
        case .claudeCode:
            ["Run the command below in your terminal"]
        case .cursor:
            [
                "Open Cursor, go to Settings > MCP",
                "Click \"+ Add new global MCP server\"",
                "Paste the JSON below and save"
            ]
        }
    }

    private var configSnippet: String? {
        switch tool {
        case .claudeDesktop, .cursor:
            """
            {
              "mcpServers": {
                "tablepro": {
                  "url": "\(url)"
                }
              }
            }
            """
        case .claudeCode: nil
        }
    }

    private var command: String? {
        switch tool {
        case .claudeCode: "claude mcp add tablepro --transport http \(url)"
        default: nil
        }
    }
}

// MARK: - Status Indicator

private struct MCPStatusIndicator: View {
    @State private var manager = MCPServerManager.shared

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .stopped: .secondary
        case .starting: .orange
        case .running: .green
        case .failed: .red
        }
    }

    private var statusText: String {
        switch manager.state {
        case .stopped:
            String(localized: "Stopped")
        case .starting:
            String(localized: "Starting...")
        case .running(let port):
            String(format: String(localized: "Running on port %d"), port)
        case .failed(let message):
            if message.contains("48") || message.lowercased().contains("address already in use") {
                String(localized: "Port is already in use. Try a different port or close the other process.")
            } else {
                String(format: String(localized: "Failed: %@"), message)
            }
        }
    }
}
