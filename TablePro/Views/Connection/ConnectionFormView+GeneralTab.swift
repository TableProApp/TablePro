//
//  ConnectionFormView+GeneralTab.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import SwiftUI
import TableProPluginKit

// MARK: - General Tab

extension ConnectionFormView {
    var generalForm: some View {
        Form {
            Section {
                Picker(String(localized: "Type"), selection: $type) {
                    ForEach(availableDatabaseTypes) { t in
                        Label {
                            HStack {
                                Text(t.rawValue)
                                if t.isDownloadablePlugin && !PluginManager.shared.isDriverLoaded(for: t) {
                                    Text("Not Installed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                }
                            }
                        } icon: {
                            t.iconImage
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                        }
                        .tag(t)
                    }
                }
                .disabled(isInstallingPlugin)
                TextField(
                    String(localized: "Name"),
                    text: $name,
                    prompt: Text("Connection name")
                )
                Button {
                    showURLImport = true
                } label: {
                    Label(String(localized: "Import from URL"), systemImage: "link")
                }
            }

            if type.isDownloadablePlugin && !PluginManager.shared.isDriverLoaded(for: type) {
                Section {
                    LabeledContent(String(localized: "Plugin")) {
                        if isInstallingPlugin {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Installing...")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let error = pluginInstallError {
                            HStack(spacing: 6) {
                                Text(error)
                                    .foregroundStyle(Color(nsColor: .systemRed))
                                    .font(.caption)
                                    .lineLimit(2)
                                Button("Retry") {
                                    pluginInstallError = nil
                                    installPlugin(for: type)
                                }
                                .controlSize(.small)
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text("Not Installed")
                                    .foregroundStyle(.secondary)
                                Button("Install") {
                                    installPlugin(for: type)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            } else if PluginManager.shared.connectionMode(for: type) == .fileBased {
                Section(String(localized: "Database File")) {
                    HStack {
                        TextField(
                            String(localized: "File Path"),
                            text: $database,
                            prompt: Text(filePathPrompt)
                        )
                        Button(String(localized: "Browse...")) { browseForFile() }
                            .controlSize(.small)
                    }
                }
            } else if PluginManager.shared.connectionMode(for: type) == .apiOnly {
                if PluginManager.shared.supportsDatabaseSwitching(for: type) {
                    Section(String(localized: "Connection")) {
                        TextField(
                            String(localized: "Database"),
                            text: $database,
                            prompt: Text("database_name")
                        )
                    }
                }
            } else {
                Section(String(localized: "Connection")) {
                    hostFieldsView
                    if PluginManager.shared.requiresAuthentication(for: type) {
                        TextField(
                            String(localized: "Database"),
                            text: $database,
                            prompt: Text("database_name")
                        )
                    }
                }

                if sshState.enabled && hasHostListField {
                    let hostListFieldId = connectionSectionFields.first {
                        if case .hostList = $0.fieldType { return true }
                        return false
                    }?.id
                    let hostsValue = hostListFieldId.flatMap { additionalFieldValues[$0] } ?? ""
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

            if PluginManager.shared.connectionMode(for: type) != .fileBased {
                Section(String(localized: "Authentication")) {
                    if PluginManager.shared.requiresAuthentication(for: type)
                        && PluginManager.shared.connectionMode(for: type) != .apiOnly
                    {
                        TextField(
                            String(localized: "Username"),
                            text: $username,
                            prompt: Text("root")
                        )
                    }
                    ForEach(authSectionFields, id: \.id) { field in
                        if isFieldVisible(field) {
                            ConnectionFieldRow(
                                field: field,
                                value: Binding(
                                    get: {
                                        additionalFieldValues[field.id]
                                            ?? field.defaultValue ?? ""
                                    },
                                    set: { additionalFieldValues[field.id] = $0 }
                                )
                            )
                        }
                    }
                    if !hidePasswordField {
                        PasswordPromptToggle(
                            type: type,
                            promptForPassword: $promptForPassword,
                            password: $password,
                            additionalFieldValues: $additionalFieldValues
                        )
                    }
                    if additionalFieldValues["usePgpass"] == "true" {
                        pgpassStatusView
                    }
                }
            }

            Section(String(localized: "Appearance")) {
                LabeledContent(String(localized: "Color")) {
                    ConnectionColorPicker(selectedColor: $connectionColor)
                }
                LabeledContent(String(localized: "Tag")) {
                    ConnectionTagEditor(selectedTagId: $selectedTagId)
                }
                LabeledContent(String(localized: "Group")) {
                    ConnectionGroupPicker(selectedGroupId: $selectedGroupId)
                }
                let isProUnlocked = LicenseManager.shared.isFeatureAvailable(.safeMode)
                Picker(String(localized: "Safe Mode"), selection: $safeModeLevel) {
                    ForEach(SafeModeLevel.allCases) { level in
                        if level.requiresPro && !isProUnlocked {
                            Text("\(level.displayName) (Pro)").tag(level)
                        } else {
                            Text(level.displayName).tag(level)
                        }
                    }
                }
                .onChange(of: safeModeLevel) { oldValue, newValue in
                    if newValue.requiresPro && !isProUnlocked {
                        safeModeLevel = oldValue
                        showSafeModeProAlert = true
                    }
                }
                .alert(
                    String(localized: "Pro License Required"),
                    isPresented: $showSafeModeProAlert
                ) {
                    Button(String(localized: "Activate License...")) {
                        showActivationSheet = true
                    }
                    Button(String(localized: "OK"), role: .cancel) {}
                } message: {
                    Text(String(localized: "Safe Mode, Safe Mode (Full), and Read-Only require a Pro license."))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showURLImport) {
            connectionURLImportSheet
        }
        .sheet(isPresented: $showActivationSheet) {
            LicenseActivationSheet()
        }
    }

    @ViewBuilder
    private var hostFieldsView: some View {
        if hasHostListField {
            ForEach(connectionSectionFields, id: \.id) { field in
                if case .hostList = field.fieldType {
                    HostListFieldRow(
                        label: field.label,
                        placeholder: field.placeholder,
                        defaultPort: type.defaultPort,
                        value: Binding(
                            get: {
                                additionalFieldValues[field.id]
                                    ?? field.defaultValue ?? ""
                            },
                            set: { additionalFieldValues[field.id] = $0 }
                        )
                    )
                }
            }
        } else {
            TextField(
                String(localized: "Host"),
                text: $host,
                prompt: Text("localhost")
            )
            TextField(
                String(localized: "Port"),
                text: $port,
                prompt: Text(defaultPort)
            )
        }
    }
}
