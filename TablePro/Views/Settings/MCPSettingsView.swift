//
//  MCPSettingsView.swift
//  TablePro
//

import SwiftUI

struct MCPSettingsView: View {
    @Bindable var settingsManager: AppSettingsManager
    @State private var manager = MCPServerManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable MCP Server", isOn: $settingsManager.mcp.enabled)

                if settingsManager.mcp.enabled {
                    HStack {
                        Text("Status")
                        Spacer()
                        MCPStatusIndicator()
                    }
                }
            }

            if settingsManager.mcp.enabled {
                configurationSection
                clientConfigurationSection
                connectedClientsSection

                Section {
                    Text("AI access policies are configured per-connection in each connection's settings.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        Section("Configuration") {
            HStack {
                Text("Port")
                Spacer()
                TextField("", value: $settingsManager.mcp.port, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("Default row limit")
                Spacer()
                TextField("", value: $settingsManager.mcp.defaultRowLimit, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("Maximum row limit")
                Spacer()
                TextField("", value: $settingsManager.mcp.maxRowLimit, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("Query timeout")
                Spacer()
                TextField("", value: $settingsManager.mcp.queryTimeoutSeconds, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text("seconds")
                    .foregroundStyle(.secondary)
            }

            Toggle("Log MCP queries in history", isOn: $settingsManager.mcp.logQueriesInHistory)
        }
    }

    // MARK: - Client Configuration

    private var clientConfigurationSection: some View {
        Section("Client Configuration") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add this to your AI tool's MCP configuration:")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                HStack {
                    Text(configSnippet)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configSnippet, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help(String(localized: "Copy to clipboard"))
                }
            }
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
                            Task {
                                await manager.disconnectClient(client.id)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var configSnippet: String {
        """
        {
          "mcpServers": {
            "tablepro": {
              "url": "http://127.0.0.1:\(settingsManager.mcp.port)/mcp"
            }
          }
        }
        """
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
        case .stopped:
            .secondary
        case .starting:
            .orange
        case .running:
            .green
        case .failed:
            .red
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

#Preview {
    MCPSettingsView(settingsManager: .shared)
        .frame(width: 450, height: 400)
}
