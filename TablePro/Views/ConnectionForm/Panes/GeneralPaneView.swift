//
//  GeneralPaneView.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

struct GeneralPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    private var type: DatabaseType { coordinator.network.type }
    private var connectionMode: ConnectionMode {
        PluginManager.shared.connectionMode(for: type)
    }

    var body: some View {
        Form {
            if let parsed = coordinator.clipboardCandidate {
                Section {
                    ClipboardConnectionBanner(
                        parsed: parsed,
                        onUse: { coordinator.applyClipboardCandidate(parsed) },
                        onDismiss: { coordinator.dismissClipboardCandidate() }
                    )
                    .listRowInsets(EdgeInsets())
                }
            }

            Section {
                TextField(
                    String(localized: "Name"),
                    text: $coordinator.network.name,
                    prompt: Text(String(localized: "Connection name"))
                )
            }

            connectionSection
            authenticationSection
            testConnectionSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var testConnectionSection: some View {
        Section {
            LabeledContent {
                TestConnectionStatusButton(coordinator: coordinator)
            } label: {
                Text(String(localized: "Status"))
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        switch connectionMode {
        case .fileBased:
            Section(String(localized: "Database File")) {
                HStack {
                    TextField(
                        String(localized: "File Path"),
                        text: $coordinator.network.database,
                        prompt: Text(filePathPrompt)
                    )
                    Button(String(localized: "Browse...")) {
                        browseForFile()
                    }
                    .controlSize(.small)
                }
            }
        case .apiOnly:
            if PluginManager.shared.supportsDatabaseSwitching(for: type) {
                Section(String(localized: "Connection")) {
                    TextField(
                        String(localized: "Database"),
                        text: $coordinator.network.database,
                        prompt: Text(String(localized: "database_name"))
                    )
                }
            } else {
                EmptyView()
            }
        case .network:
            Section(String(localized: "Connection")) {
                hostFieldsView
                if PluginManager.shared.requiresAuthentication(for: type) {
                    TextField(
                        String(localized: "Database"),
                        text: $coordinator.network.database,
                        prompt: Text(String(localized: "database_name"))
                    )
                }
            }

            if coordinator.ssh.state.enabled && coordinator.network.hasHostListField {
                let hostsValue = firstHostListValue
                if hostsValue.contains(",") {
                    Section {
                        Label(
                            String(localized: "SSH tunneling only forwards the first host. Other replica set members must be directly reachable from the SSH server."),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var hostFieldsView: some View {
        let connectionFields = coordinator.network.connectionFields
        if coordinator.network.hasHostListField {
            ForEach(connectionFields, id: \.id) { field in
                if case .hostList = field.fieldType {
                    HostListFieldRow(
                        label: field.label,
                        placeholder: field.placeholder,
                        defaultPort: type.defaultPort,
                        value: networkFieldBinding(for: field)
                    )
                }
            }
        } else {
            TextField(
                String(localized: "Host"),
                text: $coordinator.network.host,
                prompt: Text("localhost")
            )
            TextField(
                String(localized: "Port"),
                text: $coordinator.network.port,
                prompt: Text(defaultPortString)
            )
        }
        ForEach(connectionFields, id: \.id) { field in
            if !isHostListField(field) && coordinator.network.isFieldVisible(field) {
                ConnectionFieldRow(
                    field: field,
                    value: networkFieldBinding(for: field)
                )
            }
        }
    }

    @ViewBuilder
    private var authenticationSection: some View {
        if connectionMode != .fileBased {
            Section(String(localized: "Authentication")) {
                if PluginManager.shared.requiresAuthentication(for: type)
                    && connectionMode != .apiOnly {
                    TextField(
                        String(localized: "Username"),
                        text: $coordinator.auth.username,
                        prompt: Text("root")
                    )
                }
                if !coordinator.auth.hidesPassword {
                    PasswordPromptToggle(
                        type: type,
                        promptForPassword: $coordinator.auth.promptForPassword,
                        password: $coordinator.auth.password,
                        additionalFieldValues: $coordinator.auth.additionalFieldValues
                    )
                }
                ForEach(coordinator.auth.authFields, id: \.id) { field in
                    if coordinator.auth.isFieldVisible(field) {
                        ConnectionFieldRow(
                            field: field,
                            value: authFieldBinding(for: field)
                        )
                    }
                }
                if coordinator.auth.usePgpass {
                    pgpassStatusView
                }
            }
        }
    }

    @ViewBuilder
    private var pgpassStatusView: some View {
        switch coordinator.auth.pgpassStatus {
        case .notChecked:
            EmptyView()
        case .fileNotFound:
            Label(
                String(localized: "~/.pgpass not found"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(Color(nsColor: .systemYellow))
            .font(.caption)
        case .badPermissions:
            Label(
                String(localized: "~/.pgpass has incorrect permissions (needs chmod 0600)"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(Color(nsColor: .systemOrange))
            .font(.caption)
        case .matchFound:
            Label(
                String(localized: "~/.pgpass found, matching entry exists"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(Color(nsColor: .systemGreen))
            .font(.caption)
        case .noMatch:
            Label(
                String(localized: "~/.pgpass found, no matching entry"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(Color(nsColor: .systemYellow))
            .font(.caption)
        }
    }

    private func isHostListField(_ field: ConnectionField) -> Bool {
        if case .hostList = field.fieldType { return true }
        return false
    }

    private var firstHostListValue: String {
        let fieldId = coordinator.network.connectionFields
            .first(where: isHostListField)?.id
        guard let fieldId else { return "" }
        return coordinator.network.additionalFieldValues[fieldId] ?? ""
    }

    private func networkFieldBinding(for field: ConnectionField) -> Binding<String> {
        Binding(
            get: {
                coordinator.network.additionalFieldValues[field.id]
                    ?? field.defaultValue ?? ""
            },
            set: { coordinator.network.additionalFieldValues[field.id] = $0 }
        )
    }

    private func authFieldBinding(for field: ConnectionField) -> Binding<String> {
        Binding(
            get: {
                coordinator.auth.additionalFieldValues[field.id]
                    ?? field.defaultValue ?? ""
            },
            set: { coordinator.auth.additionalFieldValues[field.id] = $0 }
        )
    }

    private var defaultPortString: String {
        let port = type.defaultPort
        return port == 0 ? "" : String(port)
    }

    private var filePathPrompt: String {
        let extensions = PluginManager.shared.fileExtensions(for: type)
        let ext = (extensions.first ?? "db")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !ext.isEmpty else { return "/path/to/database.db" }
        return "/path/to/database.\(ext)"
    }

    private func browseForFile() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                coordinator.network.database = url.path(percentEncoded: false)
            }
        }
    }
}
