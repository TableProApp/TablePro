//
//  ImportFromURLSheet.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

struct ImportFromURLSheet: View {
    let onImported: (ParsedConnectionURL) -> Void
    let onCancel: () -> Void

    @State private var urlString: String = ""
    @State private var parseError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Import from URL"))
                    .font(.headline)
                Text(String(localized: "Paste a connection URL. We'll detect the database type and pre-fill the form."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField(
                String(localized: "Connection URL"),
                text: $urlString,
                prompt: Text(verbatim: "mysql://user:password@host:3306/database")
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(submit)

            if let parseError {
                Label(parseError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            } else if let parsed = parsedURL {
                previewView(parsed)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Import")) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 260)
        .onAppear(perform: prefillFromClipboard)
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedURL: ParsedConnectionURL? {
        guard !trimmedURL.isEmpty else { return nil }
        if case .success(let parsed) = ConnectionURLParser.parse(trimmedURL) {
            return parsed
        }
        return nil
    }

    private func submit() {
        guard !trimmedURL.isEmpty else { return }
        switch ConnectionURLParser.parse(trimmedURL) {
        case .success(let parsed):
            parseError = nil
            onImported(parsed)
            dismiss()
        case .failure(let error):
            parseError = error.localizedDescription
        }
    }

    private func prefillFromClipboard() {
        guard urlString.isEmpty,
              let clipString = NSPasteboard.general.string(forType: .string),
              let firstLine = clipString.components(separatedBy: .newlines).first,
              firstLine.contains("://") else { return }
        urlString = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func previewView(_ parsed: ParsedConnectionURL) -> some View {
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
