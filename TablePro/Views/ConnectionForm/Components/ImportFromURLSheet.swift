//
//  ImportFromURLSheet.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

struct ImportFromURLSheet: View {
    @Bindable var coordinator: ConnectionFormCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(String(localized: "Paste a connection URL to auto-fill the form fields."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField(
                String(localized: "Connection URL"),
                text: $coordinator.connectionURL,
                prompt: Text(urlPlaceholder)
            )
            .textFieldStyle(.roundedBorder)

            if let error = coordinator.urlParseError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            } else if let preview = parsedPreview {
                urlPreviewView(preview)
            }

            HStack {
                Button(String(localized: "Cancel")) {
                    coordinator.connectionURL = ""
                    coordinator.urlParseError = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "Import")) {
                    coordinator.parseURL()
                    if coordinator.urlParseError == nil
                        && !coordinator.connectionURL.isEmpty {
                        coordinator.connectionURL = ""
                        coordinator.urlParseError = nil
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.connectionURL
                          .trimmingCharacters(in: .whitespacesAndNewlines)
                          .isEmpty)
            }
        }
        .navigationTitle(String(localized: "Import from URL"))
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if coordinator.connectionURL.isEmpty,
               let clipString = NSPasteboard.general.string(forType: .string),
               let firstLine = clipString.components(separatedBy: .newlines).first,
               firstLine.contains("://") {
                coordinator.connectionURL = firstLine
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private var urlPlaceholder: String {
        let type = coordinator.network.type
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
        let trimmed = coordinator.connectionURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if case .success(let parsed) = ConnectionURLParser.parse(trimmed) {
            return parsed
        }
        return nil
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
