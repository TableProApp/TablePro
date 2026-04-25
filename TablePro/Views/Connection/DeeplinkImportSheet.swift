//
//  DeeplinkImportSheet.swift
//  TablePro
//

import SwiftUI

struct DeeplinkImportSheet: View {
    let connection: ExportableConnection
    let onImported: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editableName: String
    @State private var isDuplicate = false

    init(connection: ExportableConnection, onImported: @escaping () -> Void) {
        self.connection = connection
        self.onImported = onImported
        _editableName = State(initialValue: connection.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 10) {
                        DatabaseType(rawValue: connection.type).iconImage
                            .frame(width: 28, height: 28)
                        Text(DatabaseType(rawValue: connection.type).displayName)
                            .font(.headline)
                    }
                }

                Section(String(localized: "Connection")) {
                    TextField(String(localized: "Name"), text: $editableName)
                        .onChange(of: editableName) { checkDuplicate() }

                    LabeledContent(String(localized: "Host")) {
                        Text(hostDisplay)
                            .foregroundStyle(.secondary)
                    }

                    if !connection.database.isEmpty {
                        LabeledContent(String(localized: "Database")) {
                            Text(connection.database)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !connection.username.isEmpty {
                        LabeledContent(String(localized: "Username")) {
                            Text(connection.username)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if connection.sshConfig != nil {
                    sshSection
                }

                if connection.sslConfig != nil {
                    sslSection
                }

                if hasMetadata {
                    metadataSection
                }

                if isDuplicate {
                    Section {
                        Label(
                            String(localized: "A connection with this name, host, and type already exists."),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isDuplicate ? String(localized: "Add as Copy") : String(localized: "Add Connection")) {
                    performImport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editableName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
        .onAppear { checkDuplicate() }
    }

    private var hostDisplay: String {
        connection.port > 0
            ? "\(connection.host):\(connection.port)"
            : connection.host
    }

    @ViewBuilder
    private var sshSection: some View {
        if let ssh = connection.sshConfig {
            Section("SSH") {
                LabeledContent(String(localized: "Host")) {
                    let port = ssh.port != 22 ? ":\(ssh.port)" : ""
                    Text("\(ssh.host)\(port)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent(String(localized: "Auth")) {
                    Text(ssh.authMethod)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var sslSection: some View {
        if let ssl = connection.sslConfig {
            Section("SSL") {
                LabeledContent(String(localized: "Mode")) {
                    Text(ssl.mode)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var hasMetadata: Bool {
        connection.color != nil || connection.tagName != nil || connection.groupName != nil
    }

    @ViewBuilder
    private var metadataSection: some View {
        Section {
            if let color = connection.color,
               let connColor = ConnectionColor(rawValue: color), connColor != .none {
                LabeledContent(String(localized: "Color")) {
                    Circle()
                        .fill(connColor.color)
                        .frame(width: 12, height: 12)
                }
            }
            if let tagName = connection.tagName {
                LabeledContent(String(localized: "Tag")) {
                    Text(tagName).foregroundStyle(.secondary)
                }
            }
            if let groupName = connection.groupName {
                LabeledContent(String(localized: "Group")) {
                    Text(groupName).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func checkDuplicate() {
        let trimmed = editableName.trimmingCharacters(in: .whitespaces)
        let existing = ConnectionStorage.shared.loadConnections()
        isDuplicate = existing.contains {
            $0.name.lowercased() == trimmed.lowercased()
                && $0.host.lowercased() == connection.host.lowercased()
                && $0.port == connection.port
                && $0.type.rawValue.lowercased() == connection.type.lowercased()
        }
    }

    private func performImport() {
        let trimmed = editableName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let renamedConnection = connection.renamed(to: trimmed)

        let envelope = ConnectionExportEnvelope(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            connections: [renamedConnection],
            groups: connection.groupName.map { [ExportableGroup(name: $0, color: nil)] },
            tags: connection.tagName.map { [ExportableTag(name: $0, color: nil)] },
            credentials: nil
        )

        let preview = ConnectionExportService.analyzeImport(envelope)
        var resolutions: [UUID: ImportResolution] = [:]
        for item in preview.items {
            resolutions[item.id] = isDuplicate ? .importAsCopy : .importNew
        }
        ConnectionExportService.performImport(preview, resolutions: resolutions)
        onImported()
        dismiss()
    }
}
