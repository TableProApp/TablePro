//
//  IntegrationsSetupSheet.swift
//  TablePro
//

import AppKit
import SwiftUI

struct IntegrationsSetupSheet: View {
    let port: Int

    @Environment(\.dismiss) private var dismiss
    @State private var selectedClient: IntegrationClient = .claudeDesktop

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(String(localized: "Client"), selection: $selectedClient) {
                        ForEach(IntegrationClient.allCases) { client in
                            Text(client.displayName).tag(client)
                        }
                    }
                    .pickerStyle(.segmented)

                    IntegrationsSetupInstructions(client: selectedClient, port: port)
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 580, height: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Connect a Client"))
                .font(.title2.weight(.semibold))
            Text(String(localized: "Choose your client and follow the steps to connect it to TablePro."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}

private struct IntegrationsSetupInstructions: View {
    let client: IntegrationClient
    let port: Int

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
                CopyableCodeBlock(text: snippet)
            }
            if let command {
                CopyableCodeBlock(text: command)
            }
        }
        .font(.callout)
    }

    private var bridgeBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tablepro-mcp").path
    }

    private var steps: [String] {
        switch client {
        case .claudeDesktop:
            [
                String(localized: "Open Claude Desktop, go to Settings > Developer"),
                String(localized: "Click \"Edit Config\" to open claude_desktop_config.json"),
                String(localized: "Add the JSON below inside the file and save"),
                String(localized: "Restart Claude Desktop")
            ]
        case .claudeCode:
            [String(localized: "Run the command below in your terminal")]
        case .cursor:
            [
                String(localized: "Open Cursor, go to Settings > MCP"),
                String(localized: "Click \"+ Add new global MCP server\""),
                String(localized: "Paste the JSON below and save")
            ]
        case .zed:
            [
                String(localized: "Open Zed and click the Agent Panel icon in the right side of the title bar"),
                String(localized: "Click the menu in the Agent Panel header and choose Settings"),
                String(localized: "Under MCP Servers click \"+ Add Custom Server\", select the Local tab, paste the JSON below, then click Add Server")
            ]
        }
    }

    private var configSnippet: String? {
        switch client {
        case .claudeDesktop, .cursor:
            return """
            {
              "mcpServers": {
                "tablepro": {
                  "command": "\(bridgeBinaryPath)"
                }
              }
            }
            """
        case .zed:
            return """
            {
              "tablepro": {
                "command": "\(bridgeBinaryPath)",
                "args": []
              }
            }
            """
        case .claudeCode:
            return nil
        }
    }

    private var command: String? {
        switch client {
        case .claudeCode: "claude mcp add tablepro -- \(bridgeBinaryPath)"
        default: nil
        }
    }
}
