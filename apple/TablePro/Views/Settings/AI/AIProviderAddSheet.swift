import Combine
import SwiftUI

struct AIProviderAddSession: Identifiable {
    let provider: AIProviderConfig

    var id: UUID { provider.id }
}

struct AIProviderAddSheet: View {
    @StateObject private var model: AIProviderEditorModel
    private let onAdd: (AIProviderConfig, Bool) -> Void

    init(session: AIProviderAddSession, onAdd: @escaping (_ provider: AIProviderConfig, _ hasKey: Bool) -> Void) {
        self._model = StateObject(wrappedValue: AIProviderEditorModel(provider: session.provider, isNew: true))
        self.onAdd = onAdd
    }

    var body: some View {
        AIProviderAddSheetContent(model: model, loader: model.loader, onAdd: onAdd)
    }
}

private struct AIProviderAddSheetContent: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AIProviderEditorModel
    @ObservedObject var loader: AIModelListLoader
    let onAdd: (AIProviderConfig, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    header
                }
                AIProviderEditorSections(model: model, parts: .all)
            }
            .formStyle(.grouped)

            Divider()

            DialogFooter {
                if let error = model.saveError {
                    NoticeLabel(error, severity: .error)
                }
            } actions: {
                Button(String(localized: "Cancel"), role: .cancel) {
                    model.cancelTasks()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("ai-provider-cancel")

                Button(String(localized: "Add")) {
                    add()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdd)
                .accessibilityIdentifier("ai-provider-save")
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 480)
        .task {
            model.prepare()
            switch model.draft.type {
            case .copilot:
                await CopilotService.shared.start()
            case .chatgptCodex:
                await ChatGPTCodexService.shared.refreshAuthState()
            case .claudeAgent:
                await ClaudeAgentService.shared.performRefresh()
            default:
                break
            }
            await model.fetchModels()
        }
        .onDisappear {
            model.cancelTasks()
            CopilotService.shared.stopIfDisallowed(by: AppSettingsManager.shared.aiSlice.value)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandIconView(icon: model.draft.icon)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: String(format: String(localized: "Add %@"), model.draft.kindName))
                    .font(.headline)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String? {
        if let host = URL(string: model.draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host,
           !host.isEmpty {
            return host
        }
        switch model.draft.type {
        case .copilot, .chatgptCodex, .claudeAgent:
            return String(localized: "Signs in with your account")
        default:
            return nil
        }
    }

    private func add() {
        guard model.canAdd, let provider = model.providerToAdd() else { return }
        onAdd(provider, provider.authStyle.usesAPIKey && !model.apiKey.isEmpty)
        AIProviderFactory.invalidateCache(for: provider.id)
        AppEvents.shared.aiProviderSaved.send(provider.id)
        dismiss()
    }
}
