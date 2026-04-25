//
//  ConnectionFormView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import os
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

struct ConnectionFormView: View {
    static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionFormView")
    @Environment(\.openWindow) var openWindow

    // Connection ID: nil = new connection, UUID = edit existing
    let connectionId: UUID?

    let storage = ConnectionStorage.shared
    let dbManager = DatabaseManager.shared

    var isNew: Bool { connectionId == nil }

    var availableDatabaseTypes: [DatabaseType] {
        PluginManager.shared.allAvailableDatabaseTypes
    }

    var additionalConnectionFields: [ConnectionField] {
        PluginManager.shared.additionalConnectionFields(for: type)
    }

    var authSectionFields: [ConnectionField] {
        PluginManager.shared.additionalConnectionFields(for: type)
            .filter { $0.section == .authentication }
    }

    var connectionSectionFields: [ConnectionField] {
        PluginManager.shared.additionalConnectionFields(for: type)
            .filter { $0.section == .connection }
    }

    var hasHostListField: Bool {
        connectionSectionFields.contains { field in
            if case .hostList = field.fieldType { return true }
            return false
        }
    }

    func isFieldVisible(_ field: ConnectionField) -> Bool {
        guard let rule = field.visibleWhen else { return true }
        let currentValue = additionalFieldValues[rule.fieldId] ?? defaultFieldValue(rule.fieldId)
        return rule.values.contains(currentValue)
    }

    func defaultFieldValue(_ fieldId: String) -> String {
        additionalConnectionFields.first { $0.id == fieldId }?.defaultValue ?? ""
    }

    var hidePasswordField: Bool {
        authSectionFields.contains { field in
            guard field.hidesPassword else { return false }
            if case .toggle = field.fieldType {
                return additionalFieldValues[field.id] == "true"
            }
            return true
        }
    }

    @State var name: String = ""
    @State var host: String = ""
    @State var port: String = ""
    @State var database: String = ""
    @State var username: String = ""
    @State var password: String = ""
    @State var type: DatabaseType = .mysql
    @State var connectionURL: String = ""
    @State var urlParseError: String?
    @State var showURLImport = false
    @State var promptForPassword: Bool = false
    @State var hasLoadedData = false

    // SSH Configuration
    @State var sshState = SSHTunnelFormState()

    // SSL Configuration
    @State var sslMode: SSLMode = .disabled
    @State var sslCaCertPath: String = ""
    @State var sslClientCertPath: String = ""
    @State var sslClientKeyPath: String = ""

    // Color and Tag
    @State var connectionColor: ConnectionColor = .none
    @State var selectedTagId: UUID?
    @State var selectedGroupId: UUID?

    // Safe mode level
    @State var safeModeLevel: SafeModeLevel = .silent
    @State var showSafeModeProAlert = false
    @State var showActivationSheet = false

    // AI policy
    @State var aiPolicy: AIConnectionPolicy?

    // Plugin-driven additional connection fields
    @State var additionalFieldValues: [String: String] = [:]

    // Startup commands
    @State var startupCommands: String = ""

    // Pgpass
    @State var pgpassStatus: PgpassStatus = .notChecked

    var usePgpass: Bool {
        additionalFieldValues["usePgpass"] == "true"
    }

    // Pre-connect script
    @State var preConnectScript: String = ""

    // Local only (exclude from iCloud sync)
    @State var localOnly: Bool = false

    @State var isTesting: Bool = false
    @State var testSucceeded: Bool = false

    @State var pluginInstallConnection: DatabaseConnection?
    @State var isInstallingPlugin: Bool = false
    @State var pluginInstallError: String?

    // Tab selection
    @State var selectedTab: FormTab = .general

    // Store original connection for editing
    @State var originalConnection: DatabaseConnection?

    // MARK: - Enums

    enum FormTab: String, CaseIterable {
        case general = "General"
        case ssh = "SSH Tunnel"
        case ssl = "SSL/TLS"
        case advanced = "Advanced"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(visibleTabs, id: \.rawValue) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            // Tab form content
            tabForm

            Divider()

            footer
        }
        .frame(width: 480)
        .frame(minHeight: 520, idealHeight: 520)
        .navigationTitle(
            isNew ? String(localized: "New Connection") : String(localized: "Edit Connection")
        )
        .onAppear {
            loadConnectionData()
            loadSSHConfig()
        }
        .onChange(of: type) { _, newType in
            if hasLoadedData {
                port = String(newType.defaultPort)
                additionalFieldValues = [:]
                for field in PluginManager.shared.additionalConnectionFields(for: newType) {
                    if let defaultValue = field.defaultValue {
                        additionalFieldValues[field.id] = defaultValue
                    }
                }
            }
            if !visibleTabs.contains(selectedTab) {
                selectedTab = .general
            }
            isInstallingPlugin = false
            pluginInstallError = nil
        }
        .pluginInstallPrompt(connection: $pluginInstallConnection) { connection in
            connectAfterInstall(connection)
        }
        .onChange(of: pgpassTrigger) { _, _ in updatePgpassStatus() }
        .onChange(of: usePgpass) { _, newValue in if newValue { promptForPassword = false } }
    }

    // MARK: - Tab Picker Helpers

    var visibleTabs: [FormTab] {
        var tabs: [FormTab] = [.general]
        if PluginManager.shared.supportsSSH(for: type) {
            tabs.append(.ssh)
        }
        if PluginManager.shared.supportsSSL(for: type) {
            tabs.append(.ssl)
        }
        tabs.append(.advanced)
        return tabs
    }

    var resolvedSSHAgentSocketPath: String {
        sshState.resolvedAgentSocketPath
    }

    // MARK: - Tab Form Content

    @ViewBuilder
    var tabForm: some View {
        switch selectedTab {
        case .general:
            generalForm
        case .ssh:
            ConnectionSSHTunnelView(
                sshState: $sshState,
                databaseType: type
            )
        case .ssl:
            ConnectionSSLView(
                sslMode: $sslMode,
                sslCaCertPath: $sslCaCertPath,
                sslClientCertPath: $sslClientCertPath,
                sslClientKeyPath: $sslClientKeyPath
            )
        case .advanced:
            ConnectionAdvancedView(
                additionalFieldValues: $additionalFieldValues,
                startupCommands: $startupCommands,
                preConnectScript: $preConnectScript,
                aiPolicy: $aiPolicy,
                localOnly: $localOnly,
                databaseType: type,
                additionalConnectionFields: additionalConnectionFields
            )
        }
    }
}

#Preview("New Connection") {
    ConnectionFormView(connectionId: nil)
}

#Preview("Edit Connection") {
    ConnectionFormView(connectionId: DatabaseConnection.preview.id)
}
