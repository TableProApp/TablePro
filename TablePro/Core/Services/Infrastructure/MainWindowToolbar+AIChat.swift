//
//  MainWindowToolbar+AIChat.swift
//  TablePro
//
//  AI Chat toolbar items added in PR A of the chat redesign.
//  Five new identifiers join `MainWindowToolbar`:
//    - panelTabPicker  (Details / AI Chat segmented control, always visible
//                       when AI is enabled)
//    - aiModePicker    (Ask / Edit / Agent segmented control, hidden unless
//                       activeTab == .aiChat; layout-only in this PR)
//    - aiModelPicker   (provider + model dropdown, hidden unless aiChat)
//    - aiNewConversation (square.and.pencil button, hidden unless aiChat)
//    - aiHistory       (clock dropdown listing recent conversations,
//                       hidden unless aiChat)
//

import AppKit
import SwiftUI
import TableProPluginKit

extension MainWindowToolbar {
    static let panelTabPicker = NSToolbarItem.Identifier("com.TablePro.toolbar.panelTabPicker")
    static let aiModePicker = NSToolbarItem.Identifier("com.TablePro.toolbar.aiModePicker")
    static let aiModelPicker = NSToolbarItem.Identifier("com.TablePro.toolbar.aiModelPicker")
    static let aiNewConversation = NSToolbarItem.Identifier("com.TablePro.toolbar.aiNewConversation")
    static let aiHistory = NSToolbarItem.Identifier("com.TablePro.toolbar.aiHistory")

    static var aiChatItemIdentifiers: [NSToolbarItem.Identifier] {
        [aiModePicker, aiModelPicker, aiNewConversation, aiHistory]
    }

    func makePanelTabPickerItem(coordinator: MainContentCoordinator) -> NSToolbarItem {
        hostingItem(
            id: Self.panelTabPicker,
            label: String(localized: "Inspector Tab"),
            content: PanelTabPickerView(coordinator: coordinator)
        )
    }

    func makeAIModePickerItem(coordinator: MainContentCoordinator) -> NSToolbarItem {
        hostingItem(
            id: Self.aiModePicker,
            label: String(localized: "AI Mode"),
            content: AIModePickerToolbarView()
        )
    }

    func makeAIModelPickerItem(coordinator: MainContentCoordinator) -> NSToolbarItem {
        hostingItem(
            id: Self.aiModelPicker,
            label: String(localized: "AI Model"),
            content: AIModelPickerToolbarView(coordinator: coordinator)
        )
    }

    func makeAINewConversationItem(coordinator: MainContentCoordinator) -> NSToolbarItem {
        hostingItem(
            id: Self.aiNewConversation,
            label: String(localized: "New Conversation"),
            content: AINewConversationToolbarButton(coordinator: coordinator)
        )
    }

    func makeAIHistoryItem(coordinator: MainContentCoordinator) -> NSToolbarItem {
        hostingItem(
            id: Self.aiHistory,
            label: String(localized: "Conversation History"),
            content: AIHistoryMenuToolbarView(coordinator: coordinator)
        )
    }
}

// MARK: - Panel Tab Picker

private struct PanelTabPickerView: View {
    let coordinator: MainContentCoordinator
    private let settingsManager = AppSettingsManager.shared

    var body: some View {
        if settingsManager.ai.enabled, let state = coordinator.rightPanelState {
            @Bindable var bindable = state
            Picker("", selection: $bindable.activeTab) {
                ForEach(RightPanelTab.allCases, id: \.self) { tab in
                    Label(tab.localizedTitle, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .onChange(of: bindable.activeTab) { _, newValue in
                if newValue == .aiChat {
                    coordinator.splitViewController?.showInspector()
                }
            }
        } else {
            EmptyView()
        }
    }
}

// MARK: - AI Mode Picker

private struct AIModePickerToolbarView: View {
    private let settingsManager = AppSettingsManager.shared

    var body: some View {
        let binding = Binding<AIChatMode>(
            get: { settingsManager.ai.chatMode },
            set: { newValue in
                var settings = settingsManager.ai
                settings.chatMode = newValue
                settingsManager.ai = settings
            }
        )
        Picker("", selection: binding) {
            ForEach(AIChatMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

// MARK: - AI Model Picker

private struct AIModelPickerToolbarView: View {
    let coordinator: MainContentCoordinator
    private let settingsManager = AppSettingsManager.shared

    var body: some View {
        if let viewModel = coordinator.aiViewModel {
            modelMenu(viewModel: viewModel)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func modelMenu(viewModel: AIChatViewModel) -> some View {
        let providers = settingsManager.ai.providers
        if providers.isEmpty {
            EmptyView()
        } else {
            let activeProvider = settingsManager.ai.activeProvider
            let selectedProviderId = viewModel.selectedProviderId ?? activeProvider?.id
            let selectedProvider = providers.first(where: { $0.id == selectedProviderId }) ?? activeProvider
            let resolvedModel = viewModel.selectedModel ?? selectedProvider?.model ?? ""
            let label = selectedProvider.map { provider in
                resolvedModel.isEmpty ? provider.displayName : "\(provider.displayName) · \(resolvedModel)"
            } ?? String(localized: "Select Model")

            Menu {
                ForEach(providers) { provider in
                    modelMenuSection(
                        viewModel: viewModel,
                        provider: provider,
                        selectedProviderId: selectedProviderId,
                        selectedModel: resolvedModel
                    )
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text(label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Choose AI provider and model"))
        }
    }

    @ViewBuilder
    private func modelMenuSection(
        viewModel: AIChatViewModel,
        provider: AIProviderConfig,
        selectedProviderId: UUID?,
        selectedModel: String
    ) -> some View {
        let fallback = provider.model.isEmpty ? [] : [provider.model]
        let cached = viewModel.availableModels[provider.id] ?? []
        let models = cached.isEmpty ? fallback : cached

        if models.count > 1 {
            Section(provider.displayName) {
                ForEach(models, id: \.self) { model in
                    modelButton(
                        viewModel: viewModel,
                        provider: provider,
                        model: model,
                        isSelected: provider.id == selectedProviderId && model == selectedModel
                    )
                }
            }
        } else if let single = models.first {
            modelButton(
                viewModel: viewModel,
                provider: provider,
                model: single,
                isSelected: provider.id == selectedProviderId && single == selectedModel,
                showProviderPrefix: true
            )
        }
    }

    private func modelButton(
        viewModel: AIChatViewModel,
        provider: AIProviderConfig,
        model: String,
        isSelected: Bool,
        showProviderPrefix: Bool = false
    ) -> some View {
        Button {
            viewModel.selectedProviderId = provider.id
            viewModel.selectedModel = model
        } label: {
            HStack {
                if isSelected {
                    Image(systemName: "checkmark")
                }
                Text(showProviderPrefix ? "\(provider.displayName) · \(model)" : model)
            }
        }
    }
}

// MARK: - New Conversation

private struct AINewConversationToolbarButton: View {
    let coordinator: MainContentCoordinator

    var body: some View {
        Button {
            coordinator.splitViewController?.showInspector()
            coordinator.rightPanelState?.activeTab = .aiChat
            coordinator.aiViewModel?.startNewConversation()
        } label: {
            Label(String(localized: "New Conversation"), systemImage: "square.and.pencil")
        }
        .help(String(localized: "New Conversation (⇧⌘N)"))
    }
}

// MARK: - History Menu

private struct AIHistoryMenuToolbarView: View {
    let coordinator: MainContentCoordinator
    @State private var showClearConfirmation = false

    var body: some View {
        if let viewModel = coordinator.aiViewModel {
            historyMenu(viewModel: viewModel)
                .alert(
                    String(localized: "Clear All Conversations?"),
                    isPresented: $showClearConfirmation
                ) {
                    Button(String(localized: "Clear"), role: .destructive) {
                        viewModel.clearConversation()
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized: "This will permanently delete all conversation history."))
                }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func historyMenu(viewModel: AIChatViewModel) -> some View {
        Menu {
            if !viewModel.conversations.isEmpty {
                Section(String(localized: "Recent Conversations")) {
                    ForEach(viewModel.conversations) { conversation in
                        Button {
                            coordinator.splitViewController?.showInspector()
                            coordinator.rightPanelState?.activeTab = .aiChat
                            viewModel.switchConversation(to: conversation.id)
                        } label: {
                            HStack {
                                Text(conversation.title.isEmpty
                                    ? String(localized: "Untitled")
                                    : conversation.title)
                                if conversation.id == viewModel.activeConversationID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Divider()
            }
            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Label(String(localized: "Clear Recents"), systemImage: "trash")
            }
            .disabled(viewModel.conversations.isEmpty)
        } label: {
            Label(String(localized: "Conversation History"), systemImage: "clock")
        }
        .help(String(localized: "Conversation history"))
    }
}
