//
//  AISettingsView.swift
//  TablePro
//
//  Single settings tab for AI: providers, active provider, inline suggestions,
//  context, and privacy. Modeled after Xcode 26 Intelligence settings.
//

import SwiftUI

struct AISettingsView: View {
    @Binding var settings: AISettings

    @State private var editingProviderID: UUID?
    @State private var addingProviderType: AIProviderType?
    @State private var pendingDeleteID: UUID?
    @State private var copilotService = CopilotService.shared
    @State private var providersWithKey: Set<UUID> = []

    var body: some View {
        Form {
            enableSection
            if settings.enabled {
                activeProviderSection
                providersSection
                inlineSuggestionsSection
                contextSection
                CustomSlashCommandsSection(storage: CustomSlashCommandStorage.shared)
                privacySection
            }
        }
        .formStyle(.grouped)
        .task { refreshKeyAvailability() }
        .onChange(of: settings.providers.map(\.id)) {
            refreshKeyAvailability()
        }
        .sheet(item: editingProviderBinding) { provider in
            AIProviderDetailSheet(
                provider: provider,
                initialAPIKey: AIKeyStorage.shared.loadAPIKey(for: provider.id) ?? "",
                isNew: false,
                onSave: { saved, apiKey in
                    saveProvider(saved, apiKey: apiKey, isNew: false)
                    editingProviderID = nil
                },
                onDelete: {
                    pendingDeleteID = provider.id
                    editingProviderID = nil
                },
                onCancel: {
                    editingProviderID = nil
                }
            )
        }
        .sheet(item: $addingProviderType) { type in
            AIProviderDetailSheet(
                provider: makeNewProvider(type: type),
                initialAPIKey: "",
                isNew: true,
                onSave: { saved, apiKey in
                    saveProvider(saved, apiKey: apiKey, isNew: true)
                    addingProviderType = nil
                },
                onDelete: nil,
                onCancel: {
                    addingProviderType = nil
                }
            )
        }
        .alert(deleteAlertTitle, isPresented: deleteAlertBinding) {
            Button(String(localized: "Remove"), role: .destructive) {
                if let id = pendingDeleteID {
                    removeProvider(id)
                }
                pendingDeleteID = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingDeleteID = nil
            }
        } message: {
            Text(String(localized: "The API key will be permanently deleted."))
        }
    }

    // MARK: - Enable

    private var enableSection: some View {
        Section {
            Toggle("Enable AI Features", isOn: $settings.enabled)
        }
    }

    // MARK: - Active Provider

    private var activeProviderSection: some View {
        Section {
            HStack {
                Text("Active Provider")
                Spacer()
                Picker("", selection: $settings.activeProviderID) {
                    Text("None").tag(UUID?.none)
                    ForEach(settings.providers) { provider in
                        Text(provider.displayName).tag(UUID?.some(provider.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(settings.providers.isEmpty)
            }
        }
    }

    // MARK: - Providers

    private var providersSection: some View {
        Section {
            if settings.providers.isEmpty {
                emptyProvidersRow
            } else {
                ForEach(settings.providers) { provider in
                    Button {
                        editingProviderID = provider.id
                    } label: {
                        providerRow(provider)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(String(localized: "Edit")) {
                            editingProviderID = provider.id
                        }
                        Button(String(localized: "Set as Active")) {
                            settings.activeProviderID = provider.id
                        }
                        .disabled(settings.activeProviderID == provider.id)
                        Divider()
                        Button(String(localized: "Remove"), role: .destructive) {
                            pendingDeleteID = provider.id
                        }
                    }
                }
            }
            addProviderMenu
        } header: {
            Text("Providers")
        }
    }

    private var emptyProvidersRow: some View {
        HStack {
            Spacer()
            Text("No providers configured")
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func providerRow(_ provider: AIProviderConfig) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if provider.id == settings.activeProviderID {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 14)

            Image(systemName: provider.type.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .fontWeight(.regular)
                Text(statusText(for: provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var addProviderMenu: some View {
        Menu {
            ForEach(orderedAddableTypes, id: \.self) { type in
                Button {
                    addingProviderType = type
                } label: {
                    Label(type.displayName, systemImage: type.symbolName)
                }
            }
            Divider()
            Button {
                addingProviderType = .custom
            } label: {
                Label(String(localized: "Add Custom Provider…"), systemImage: AIProviderType.custom.symbolName)
            }
        } label: {
            Label(String(localized: "Add Provider…"), systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var orderedAddableTypes: [AIProviderType] {
        [.copilot, .claude, .openAI, .openRouter, .gemini, .ollama]
    }

    // MARK: - Inline Suggestions

    private var inlineSuggestionsSection: some View {
        Section {
            Toggle("Enable inline suggestions while typing", isOn: $settings.inlineSuggestionsEnabled)
                .disabled(!settings.hasActiveProvider)
                .help(settings.hasActiveProvider
                    ? ""
                    : String(localized: "Configure an active provider to enable inline suggestions."))
        } header: {
            Text("Inline Suggestions")
        } footer: {
            Text("Inline SQL suggestions appear as you type. Press Tab to accept, Escape to dismiss.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Context

    private var contextSection: some View {
        Section {
            Toggle("Include database schema", isOn: $settings.includeSchema)
            Toggle("Include current query", isOn: $settings.includeCurrentQuery)
            Toggle("Include query results", isOn: $settings.includeQueryResults)
            Stepper(
                String(format: String(localized: "Max schema tables: %d"), settings.maxSchemaTables),
                value: $settings.maxSchemaTables,
                in: 1...100
            )
        } header: {
            Text("Context")
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            Picker("Connection policy", selection: $settings.defaultConnectionPolicy) {
                ForEach(AIConnectionPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Privacy")
        }
    }

    // MARK: - Bindings

    private var editingProviderBinding: Binding<AIProviderConfig?> {
        Binding<AIProviderConfig?>(
            get: {
                guard let id = editingProviderID else { return nil }
                return settings.providers.first(where: { $0.id == id })
            },
            set: { newValue in
                editingProviderID = newValue?.id
            }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding<Bool>(
            get: { pendingDeleteID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteID = nil
                }
            }
        )
    }

    private var deleteAlertTitle: String {
        guard let id = pendingDeleteID,
              let provider = settings.providers.first(where: { $0.id == id }) else {
            return String(localized: "Remove Provider?")
        }
        return String(format: String(localized: "Remove %@?"), provider.displayName)
    }

    // MARK: - Status text

    private func statusText(for provider: AIProviderConfig) -> String {
        switch provider.type.authStyle {
        case .oauth:
            return copilotStatusText()
        case .apiKey:
            if provider.type == .custom {
                return customStatusText(for: provider)
            }
            return providersWithKey.contains(provider.id)
                ? String(localized: "API key set")
                : String(localized: "Not configured")
        case .none:
            if provider.type == .ollama {
                let endpoint = provider.endpoint.isEmpty ? provider.type.defaultEndpoint : provider.endpoint
                if let host = URL(string: endpoint)?.host, host == "localhost" || host == "127.0.0.1" {
                    return String(localized: "Local")
                }
                return endpoint
            }
            return provider.endpoint.isEmpty
                ? String(localized: "Not configured")
                : provider.endpoint
        }
    }

    private func copilotStatusText() -> String {
        switch copilotService.authState {
        case .signedIn(let username):
            return String(format: String(localized: "Signed in as %@"), username)
        case .signingIn:
            return String(localized: "Signing in…")
        case .signedOut:
            return String(localized: "Not signed in")
        }
    }

    private func customStatusText(for provider: AIProviderConfig) -> String {
        if providersWithKey.contains(provider.id) {
            return String(localized: "API key set")
        }
        if let host = URL(string: provider.endpoint)?.host, !host.isEmpty {
            return host
        }
        return String(localized: "Not configured")
    }

    private func refreshKeyAvailability() {
        var ids: Set<UUID> = []
        for provider in settings.providers where provider.type.authStyle == .apiKey {
            if let key = AIKeyStorage.shared.loadAPIKey(for: provider.id), !key.isEmpty {
                ids.insert(provider.id)
            }
        }
        providersWithKey = ids
    }

    // MARK: - Mutations

    private func makeNewProvider(type: AIProviderType) -> AIProviderConfig {
        AIProviderConfig(
            id: UUID(),
            name: "",
            type: type,
            model: "",
            endpoint: type.defaultEndpoint,
            maxOutputTokens: nil,
            telemetryEnabled: type == .copilot ? true : false
        )
    }

    private func saveProvider(_ provider: AIProviderConfig, apiKey: String, isNew: Bool) {
        if provider.type.authStyle == .apiKey {
            AIKeyStorage.shared.saveAPIKey(apiKey, for: provider.id)
        }

        if let index = settings.providers.firstIndex(where: { $0.id == provider.id }) {
            settings.providers[index] = provider
        } else {
            settings.providers.append(provider)
        }

        AIProviderFactory.invalidateCache(for: provider.id)
        refreshKeyAvailability()

        if isNew, settings.activeProviderID == nil {
            settings.activeProviderID = provider.id
        }
    }

    private func removeProvider(_ id: UUID) {
        AIKeyStorage.shared.deleteAPIKey(for: id)
        AIProviderFactory.invalidateCache(for: id)
        settings.providers.removeAll { $0.id == id }
        if settings.activeProviderID == id {
            settings.activeProviderID = nil
        }
        refreshKeyAvailability()
    }
}
