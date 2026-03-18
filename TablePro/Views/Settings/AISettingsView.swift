//
//  AISettingsView.swift
//  TablePro
//
//  Settings tab for AI provider configuration, feature routing, and context options.
//

import SwiftUI

/// AI settings tab in the Settings window
struct AISettingsView: View {
    @Binding var settings: AISettings

    @State private var selectedProviderID: UUID?
    @State private var editingProvider: AIProviderConfig?
    @State private var editingProviderAPIKey: String = ""
    @State private var isAddingNewProvider: Bool = false

    var body: some View {
        Form {
            providersSection
            featureRoutingSection
            contextSection
            inlineSuggestionsSection
            privacySection
        }
        .formStyle(.grouped)
        .sheet(item: $editingProvider) { provider in
            AIProviderEditorSheet(
                provider: provider,
                initialAPIKey: editingProviderAPIKey,
                isNew: isAddingNewProvider,
                onSave: { savedProvider, apiKey in
                    saveProvider(savedProvider, apiKey: apiKey)
                    editingProvider = nil
                },
                onCancel: {
                    if isAddingNewProvider {
                        // Discard the provider that was never saved
                    }
                    editingProvider = nil
                }
            )
        }
    }

    // MARK: - Providers Section

    private var providersSection: some View {
        Section {
            VStack(spacing: 0) {
                if settings.providers.isEmpty {
                    Text(String(localized: "No providers configured"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    List(selection: $selectedProviderID) {
                        ForEach(settings.providers) { provider in
                            providerRow(provider)
                                .tag(provider.id)
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        openEditSheet(for: provider)
                                    }
                                )
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .frame(height: max(80, min(CGFloat(settings.providers.count) * 48, 200)))
                }

                Divider()

                HStack(spacing: 0) {
                    Button {
                        removeSelectedProvider()
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 24, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedProviderID == nil)

                    Divider()
                        .frame(height: 16)

                    Button {
                        addProvider()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 20)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button {
                        if let id = selectedProviderID,
                           let provider = settings.providers.first(where: { $0.id == id }) {
                            openEditSheet(for: provider)
                        }
                    } label: {
                        Image(systemName: "pencil")
                            .frame(width: 24, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedProviderID == nil)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        } header: {
            Text("Providers")
        }
    }

    private func providerRow(_ provider: AIProviderConfig) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconForProviderType(provider.type))
                .foregroundStyle(provider.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name.isEmpty ? provider.type.displayName : provider.name)
                    .fontWeight(.medium)
                Text(provider.model.isEmpty ? String(localized: "No model selected") : provider.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !provider.isEnabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Feature Routing Section

    private var featureRoutingSection: some View {
        Section {
            ForEach(AIFeature.allCases) { feature in
                HStack {
                    Text(feature.displayName)
                    Spacer()
                    Picker("", selection: featureRouteBinding(for: feature)) {
                        Text(String(localized: "Default")).tag(UUID?.none as UUID?)
                        ForEach(settings.providers.filter(\.isEnabled)) { provider in
                            Text(provider.name.isEmpty ? provider.type.displayName : provider.name)
                                .tag(UUID?.some(provider.id) as UUID?)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        } header: {
            Text("Feature Routing")
        }
    }

    // MARK: - Context Section

    private var contextSection: some View {
        Section {
            Toggle(String(localized: "Include database schema"), isOn: $settings.includeSchema)
            Toggle(String(localized: "Include current query"), isOn: $settings.includeCurrentQuery)
            Toggle(String(localized: "Include query results"), isOn: $settings.includeQueryResults)

            Stepper(
                String(localized: "Max schema tables: \(settings.maxSchemaTables)"),
                value: $settings.maxSchemaTables,
                in: 1...100
            )
        } header: {
            Text("Context")
        }
    }

    // MARK: - Inline Suggestions Section

    private var inlineSuggestionsSection: some View {
        Section {
            Toggle(String(localized: "Enable inline suggestions"), isOn: $settings.inlineSuggestEnabled)
            Text(String(localized: "AI-powered SQL completions appear as ghost text while typing. Press Tab to accept, Escape to dismiss."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Inline Suggestions")
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        Section {
            Picker(
                String(localized: "Default connection policy"),
                selection: $settings.defaultConnectionPolicy
            ) {
                ForEach(AIConnectionPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
        } header: {
            Text("Privacy")
        }
    }

    // MARK: - Actions

    private func addProvider() {
        let newProvider = AIProviderConfig()
        editingProviderAPIKey = ""
        isAddingNewProvider = true
        editingProvider = newProvider
    }

    private func removeSelectedProvider() {
        guard let selectedID = selectedProviderID else { return }
        removeProvider(selectedID)
    }

    private func removeProvider(_ id: UUID) {
        settings.providers.removeAll { $0.id == id }
        AIKeyStorage.shared.deleteAPIKey(for: id)
        if selectedProviderID == id {
            selectedProviderID = nil
        }
        // Clean up feature routing references
        for key in settings.featureRouting.keys {
            if settings.featureRouting[key]?.providerID == id {
                settings.featureRouting.removeValue(forKey: key)
            }
        }
    }

    private func openEditSheet(for provider: AIProviderConfig) {
        editingProviderAPIKey = AIKeyStorage.shared.loadAPIKey(for: provider.id) ?? ""
        isAddingNewProvider = false
        editingProvider = provider
    }

    private func saveProvider(_ provider: AIProviderConfig, apiKey: String) {
        // Save API key to Keychain
        if provider.type.requiresAPIKey {
            AIKeyStorage.shared.saveAPIKey(apiKey, for: provider.id)
        }

        // Update or append provider
        if let existingIndex = settings.providers.firstIndex(where: { $0.id == provider.id }) {
            settings.providers[existingIndex] = provider
        } else {
            settings.providers.append(provider)
        }

        isAddingNewProvider = false
    }

    // MARK: - Helpers

    private func featureRouteBinding(for feature: AIFeature) -> Binding<UUID?> {
        Binding(
            get: { settings.featureRouting[feature.rawValue]?.providerID },
            set: { newValue in
                if let providerID = newValue {
                    let model = settings.providers.first(where: { $0.id == providerID })?.model ?? ""
                    settings.featureRouting[feature.rawValue] = AIFeatureRoute(
                        providerID: providerID,
                        model: model
                    )
                } else {
                    settings.featureRouting.removeValue(forKey: feature.rawValue)
                }
            }
        )
    }

    private func iconForProviderType(_ type: AIProviderType) -> String {
        switch type {
        case .claude: return "brain"
        case .openAI: return "cpu"
        case .openRouter: return "arrow.triangle.branch"
        case .ollama: return "desktopcomputer"
        case .gemini: return "sparkle"
        case .custom: return "gearshape"
        }
    }
}

// MARK: - Provider Editor Sheet

/// Modal sheet for adding or editing an AI provider configuration.
/// Operates on a draft copy; Cancel discards changes, Save commits them.
private struct AIProviderEditorSheet: View {
    private let initialProvider: AIProviderConfig
    private let isNew: Bool
    private let onSave: (AIProviderConfig, String) -> Void
    private let onCancel: () -> Void

    @State private var draft: AIProviderConfig
    @State private var editingAPIKey: String
    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?
    @State private var fetchedModels: [String] = []
    @State private var isFetchingModels: Bool = false
    @State private var modelFetchError: String?
    @State private var modelFetchTask: Task<Void, Never>?
    @State private var testTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss

    private enum TestResult {
        case success
        case failure(String)
    }

    init(
        provider: AIProviderConfig,
        initialAPIKey: String,
        isNew: Bool,
        onSave: @escaping (AIProviderConfig, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialProvider = provider
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: provider)
        _editingAPIKey = State(initialValue: initialAPIKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            sheetForm
            Divider()
            sheetFooter
        }
        .frame(minWidth: 420, minHeight: 400)
        .onAppear {
            fetchModels()
        }
        .onDisappear {
            modelFetchTask?.cancel()
            testTask?.cancel()
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        Text(isNew ? String(localized: "Add Provider") : String(localized: "Edit Provider"))
            .font(.headline)
            .padding()
    }

    // MARK: - Form

    private var sheetForm: some View {
        Form {
            Section {
                typePicker
                nameField
                if draft.type.requiresAPIKey {
                    apiKeyField
                }
                endpointField
                modelField
                enabledToggle
                testRow
            }
        }
        .formStyle(.grouped)
    }

    private var typePicker: some View {
        Picker(String(localized: "Type"), selection: $draft.type) {
            ForEach(AIProviderType.allCases) { type in
                Text(type.displayName).tag(type)
            }
        }
        .onChange(of: draft.type) { _, newType in
            let allDefaults = AIProviderType.allCases.map(\.defaultEndpoint)
            if draft.endpoint.isEmpty || allDefaults.contains(draft.endpoint) {
                draft.endpoint = newType.defaultEndpoint
            }
            fetchedModels = []
            draft.model = ""
            scheduleFetchModels()
        }
    }

    private var nameField: some View {
        TextField(String(localized: "Name"), text: $draft.name)
            .textFieldStyle(.roundedBorder)
    }

    private var apiKeyField: some View {
        SecureField("API Key", text: $editingAPIKey)
            .textFieldStyle(.roundedBorder)
            .onChange(of: editingAPIKey) {
                scheduleFetchModels()
            }
    }

    private var endpointField: some View {
        TextField("Endpoint", text: $draft.endpoint)
            .textFieldStyle(.roundedBorder)
            .onChange(of: draft.endpoint) {
                fetchedModels = []
                scheduleFetchModels()
            }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            if fetchedModels.isEmpty {
                HStack {
                    Text("Model")
                    Spacer()
                    if isFetchingModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(String(localized: "No models loaded"))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Picker("Model", selection: $draft.model) {
                    if !fetchedModels.contains(draft.model) && !draft.model.isEmpty {
                        Text(draft.model).tag(draft.model)
                    }
                    ForEach(fetchedModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }

            if let error = modelFetchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var enabledToggle: some View {
        Toggle(String(localized: "Enabled"), isOn: $draft.isEnabled)
    }

    private var testRow: some View {
        HStack {
            Spacer()
            Button {
                testProvider()
            } label: {
                HStack(spacing: 4) {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: testResultIcon)
                            .foregroundStyle(testResultColor)
                    }
                    Text("Test")
                }
            }
            .disabled(isTesting)

            if case .success = testResult {
                Text(String(localized: "Connection successful"))
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if case .failure(let message) = testResult {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack {
            Button(String(localized: "Cancel")) {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(String(localized: "Save")) {
                onSave(draft, editingAPIKey)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Model Fetching

    private func scheduleFetchModels() {
        modelFetchTask?.cancel()
        modelFetchTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            fetchModels()
        }
    }

    private func fetchModels() {
        let provider = AIProviderFactory.createProvider(for: draft, apiKey: editingAPIKey)

        isFetchingModels = true
        modelFetchError = nil

        modelFetchTask = Task {
            do {
                let models = try await provider.fetchAvailableModels()
                fetchedModels = models

                // Auto-select first model if field is empty
                if draft.model.isEmpty, let first = models.first {
                    draft.model = first
                }

                isFetchingModels = false
            } catch {
                modelFetchError = error.localizedDescription
                isFetchingModels = false
            }
        }
    }

    // MARK: - Connection Test

    func testProvider() {
        let provider = AIProviderFactory.createProvider(for: draft, apiKey: editingAPIKey)

        isTesting = true
        testResult = nil

        testTask = Task {
            do {
                let success = try await provider.testConnection()
                isTesting = false
                testResult = success ? .success : .failure(String(localized: "Connection test failed"))
            } catch {
                isTesting = false
                testResult = .failure(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private var testResultIcon: String {
        switch testResult {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .none: return "bolt.horizontal"
        }
    }

    private var testResultColor: Color {
        switch testResult {
        case .success: return .green
        case .failure: return .red
        case .none: return .secondary
        }
    }
}
