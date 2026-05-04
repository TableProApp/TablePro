//
//  ConnectionFormView+Footer.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import SwiftUI
import TableProPluginKit

// MARK: - Footer

extension ConnectionFormView {
    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Test connection
                Button(action: testConnection) {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else if testSucceeded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(nsColor: .systemGreen))
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                        }
                        Text(testSucceeded ? String(localized: "Connected") : String(localized: "Test Connection"))
                    }
                }
                .disabled(isTesting || isInstallingPlugin || !isValid)

                if !isNew {
                    Button("Delete", role: .destructive) {
                        Task {
                            let confirmed = await AlertHelper.confirmDestructive(
                                title: String(localized: "Delete Connection"),
                                message: String(localized: "Are you sure you want to delete this connection? This cannot be undone."),
                                confirmButton: String(localized: "Delete"),
                                window: NSApp.keyWindow
                            )
                            if confirmed {
                                deleteConnection()
                            }
                        }
                    }
                }

                Spacer()

                // Cancel
                Button("Cancel") {
                    dismiss()
                }

                if isNew {
                    Button(String(localized: "Save")) {
                        saveConnection(connect: false)
                    }
                    .disabled(isInstallingPlugin || !isValid)
                }

                Button(isNew ? String(localized: "Save & Connect") : String(localized: "Save")) {
                    saveConnection(connect: isNew)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(isInstallingPlugin || !isValid)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            dismiss()
        }
        .onChange(of: host) { _, _ in testSucceeded = false }
        .onChange(of: port) { _, _ in testSucceeded = false }
        .onChange(of: username) { _, _ in testSucceeded = false }
        .onChange(of: password) { _, _ in testSucceeded = false }
        .onChange(of: database) { _, _ in testSucceeded = false }
        .onChange(of: type) { _, _ in testSucceeded = false }
        .onChange(of: sshState.enabled) { _, _ in testSucceeded = false }
        .onChange(of: sshState.host) { _, _ in testSucceeded = false }
        .onChange(of: sshState.port) { _, _ in testSucceeded = false }
        .onChange(of: sshState.username) { _, _ in testSucceeded = false }
        .onChange(of: sshState.authMethod) { _, _ in testSucceeded = false }
        .onChange(of: sslMode) { _, _ in testSucceeded = false }
        .onChange(of: additionalFieldValues) { _, _ in testSucceeded = false }
    }

    // MARK: - Import from URL Sheet

    private var urlPlaceholder: String {
        let snapshot = PluginMetadataRegistry.shared.snapshot(forTypeId: type.pluginTypeId)
        let scheme = snapshot?.primaryUrlScheme ?? type.rawValue.lowercased()
        let mode = snapshot?.connectionMode ?? .network

        switch mode {
        case .fileBased:
            return "\(scheme):///path/to/database"
        case .apiOnly:
            if type.pluginTypeId == "libSQL" {
                return "libsql://your-database.turso.io"
            }
            if type.pluginTypeId == "Cloudflare D1" {
                return "d1://account-id/database-name"
            }
            return "\(scheme)://host/database"
        case .network:
            let port = snapshot?.defaultPort ?? 0
            let portStr = port > 0 ? ":\(port)" : ""
            return "\(scheme)://user:password@host\(portStr)/database"
        }
    }

    private var parsedPreview: ParsedConnectionURL? {
        let trimmed = connectionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if case .success(let parsed) = ConnectionURLParser.parse(trimmed) {
            return parsed
        }
        return nil
    }

    var connectionURLImportSheet: some View {
        VStack(spacing: 16) {
            Text("Paste a connection URL to auto-fill the form fields.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField(
                String(localized: "Connection URL"),
                text: $connectionURL,
                prompt: Text(urlPlaceholder)
            )
            .textFieldStyle(.roundedBorder)

            if let urlParseError {
                Text(urlParseError)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
            } else if let preview = parsedPreview {
                urlPreviewView(preview)
            }

            HStack {
                Button("Cancel") {
                    connectionURL = ""
                    urlParseError = nil
                    showURLImport = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import") {
                    parseConnectionURL()
                    if urlParseError == nil && !connectionURL.isEmpty {
                        connectionURL = ""
                        urlParseError = nil
                        showURLImport = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(connectionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(String(localized: "Import from URL"))
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if connectionURL.isEmpty,
               let clipString = NSPasteboard.general.string(forType: .string),
               let firstLine = clipString.components(separatedBy: .newlines).first,
               firstLine.contains("://")
            {
                connectionURL = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func urlPreviewView(_ parsed: ParsedConnectionURL) -> some View {
        let snapshot = PluginMetadataRegistry.shared.snapshot(forTypeId: parsed.type.pluginTypeId)
        let mode = snapshot?.connectionMode ?? .network

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(parsed.type.iconName)
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(snapshot?.displayName ?? parsed.type.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            switch mode {
            case .fileBased:
                if !parsed.database.isEmpty {
                    previewRow(String(localized: "Path"), parsed.database)
                }
            case .apiOnly:
                if !parsed.host.isEmpty {
                    previewRow(String(localized: "Host"), parsed.host)
                }
            case .network:
                if let multiHost = parsed.multiHost, multiHost.contains(",") {
                    previewRow(String(localized: "Hosts"), multiHost)
                } else if !parsed.host.isEmpty {
                    let portStr = parsed.port.map { ":\($0)" } ?? ""
                    previewRow(String(localized: "Host"), parsed.host + portStr)
                }
                if !parsed.username.isEmpty {
                    previewRow(String(localized: "User"), parsed.username)
                }
                if !parsed.database.isEmpty {
                    previewRow(String(localized: "Database"), parsed.database)
                }
                if let svc = parsed.oracleServiceName, !svc.isEmpty {
                    previewRow(String(localized: "Service"), svc)
                }
                if let sshHost = parsed.sshHost {
                    previewRow("SSH", sshHost)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func previewRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
