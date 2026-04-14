//
//  AIChatPanelView.swift
//  TablePro
//
//  AI chat panel view - right-side panel for conversing with AI about database queries.
//

import SwiftUI

/// AI chat panel displayed alongside the main editor content
struct AIChatPanelView: View {
    let connection: DatabaseConnection
    let tables: [TableInfo]
    var currentQuery: String?
    var queryResults: String?

    @Bindable var viewModel: AIChatViewModel
    private let settingsManager = AppSettingsManager.shared
    @State private var isUserScrolledUp = false
    @State private var scrollProxy: ScrollViewProxy?
    @State private var lastAutoScrollTime: Date = .distantPast

    private var hasConfiguredProvider: Bool {
        settingsManager.ai.providers.contains(where: { $0.isEnabled })
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !hasConfiguredProvider && viewModel.messages.isEmpty {
                noProviderState
            } else if viewModel.messages.isEmpty {
                emptyState
            } else {
                messageList
            }

            if hasConfiguredProvider {
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                inputArea
            }
        }
        .onAppear {
            viewModel.connection = connection
        }
        .task(id: tables) {
            viewModel.tables = tables
            viewModel.fetchSchemaContext()
        }
        .alert(
            String(localized: "Allow AI Access"),
            isPresented: $viewModel.showAIAccessConfirmation
        ) {
            Button(String(localized: "Allow")) {
                viewModel.confirmAIAccess()
            }
            Button(String(localized: "Don't Allow"), role: .cancel) {
                viewModel.denyAIAccess()
            }
        } message: {
            Text(String(localized: "Your database schema and query data will be sent to the AI provider for analysis. Allow for this connection?"))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            // Left: New conversation button
            Button {
                viewModel.startNewConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help(String(localized: "New Conversation"))

            Spacer()

            // Center: Conversation title as dropdown
            Menu {
                if !viewModel.conversations.isEmpty {
                    Section(String(localized: "Recent Conversations")) {
                        ForEach(viewModel.conversations) { conversation in
                            Button {
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
                    viewModel.clearConversation()
                } label: {
                    Label(String(localized: "Clear Recents"), systemImage: "trash")
                }
                .disabled(viewModel.conversations.isEmpty)
            } label: {
                VStack(spacing: 2) {
                    let title = viewModel.conversations
                        .first(where: { $0.id == viewModel.activeConversationID })?.title
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    Text(title.isEmpty ? String(localized: "New Chat") : title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let connectionName = viewModel.connection?.name {
                        Text(connectionName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            // Right: Spacer to balance layout (history menu removed)
            Color.clear
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: - Empty States

    private var emptyState: some View {
        EmptyStateView(
            icon: "sparkles",
            title: String(localized: "Ask AI about your database"),
            description: String(localized: "Get help writing queries, explaining schemas, or fixing errors.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noProviderState: some View {
        EmptyStateView(
            icon: "gear",
            title: String(localized: "AI Not Configured"),
            description: String(localized: "Configure an AI provider in Settings to start chatting."),
            actionTitle: String(localized: "Go to Settings…"),
            action: {
                UserDefaults.standard.set(SettingsTab.ai.rawValue, forKey: "selectedSettingsTab")
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    private var messageList: some View {
        ZStack(alignment: .bottom) {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.messages) { message in
                        if message.role != .system {
                            // Extra spacing before user messages to separate conversation turns
                            if message.role == .user,
                               let msgIndex = viewModel.messages.firstIndex(where: { $0.id == message.id }),
                               msgIndex > 0,
                               viewModel.messages[msgIndex - 1].role == .assistant
                            {
                                Spacer()
                                    .frame(height: 16)
                            }
                            AIChatMessageView(
                                message: message,
                                onRetry: shouldShowRetry(for: message) ? { viewModel.retry() } : nil,
                                onRegenerate: shouldShowRegenerate(for: message) ? { viewModel.regenerate() } : nil,
                                onEdit: message.role == .user && !viewModel.isStreaming
                                    ? { viewModel.editMessage(message) } : nil
                            )
                            .padding(.vertical, 4)
                            .id(message.id)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottomAnchor")
                        .onAppear { isUserScrolledUp = false }
                        .onDisappear { isUserScrolledUp = true }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                scrollProxy = proxy
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.messages.count) {
                isUserScrolledUp = false
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.activeConversationID) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.messages.last?.content) {
                guard !isUserScrolledUp else { return }
                let now = Date()
                guard now.timeIntervalSince(lastAutoScrollTime) >= 0.1 else { return }
                lastAutoScrollTime = now
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, newValue in
                if !newValue, !isUserScrolledUp {
                    scrollToBottom(proxy: proxy)
                }
            }
        }

        if isUserScrolledUp, let proxy = scrollProxy {
            Button {
                isUserScrolledUp = false
                scrollToBottom(proxy: proxy)
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: isUserScrolledUp)
        }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemYellow))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss error"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .systemYellow).opacity(0.1))
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 8) {
                TextField(
                    String(localized: "Ask about your database..."),
                    text: $viewModel.inputText,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit {
                    if !NSEvent.modifierFlags.contains(.shift) {
                        updateContext()
                        viewModel.sendMessage()
                    }
                }

                if viewModel.isStreaming {
                    Button {
                        viewModel.cancelStream()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemRed))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Stop Generating"))
                } else {
                    Button {
                        updateContext()
                        viewModel.sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(
                                viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? .secondary : Color.accentColor
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(String(localized: "Send Message"))
                }
            }
            .padding(8)
        }
    }

    // MARK: - Helpers

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastID = viewModel.messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    private func updateContext() {
        viewModel.currentQuery = currentQuery
        viewModel.queryResults = queryResults
    }

    private func shouldShowRetry(for message: AIChatMessage) -> Bool {
        message.role == .user
            && message.id == viewModel.messages.last?.id
            && viewModel.lastMessageFailed
    }

    private func shouldShowRegenerate(for message: AIChatMessage) -> Bool {
        message.role == .assistant
            && message.id == viewModel.messages.last?.id
            && !viewModel.isStreaming
            && !message.content.isEmpty
    }
}
