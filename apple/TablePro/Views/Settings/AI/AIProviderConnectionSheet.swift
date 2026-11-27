import Combine
import SwiftUI

struct AIProviderConnectionSaved: Equatable {
    let connectionChanged: Bool
    let hasKey: Bool
}

// Edits the name, Base URL and key of a saved provider; the page commits everything else live.
struct AIProviderConnectionSheet: View {
    @StateObject private var model: AIProviderEditorModel
    private let slice: SettingsSlice<AISettings>
    private let onSaved: (AIProviderConnectionSaved) -> Void

    init(
        provider: AIProviderConfig,
        slice: SettingsSlice<AISettings>,
        onSaved: @escaping (AIProviderConnectionSaved) -> Void
    ) {
        self._model = StateObject(wrappedValue: AIProviderEditorModel(provider: provider, isNew: false))
        self.slice = slice
        self.onSaved = onSaved
    }

    var body: some View {
        AIProviderConnectionSheetContent(model: model, slice: slice, onSaved: onSaved)
    }
}

private struct AIProviderConnectionSheetContent: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AIProviderEditorModel
    let slice: SettingsSlice<AISettings>
    let onSaved: (AIProviderConnectionSaved) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                AIProviderEditorSections(model: model, parts: [.connection, .apiKey])
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

                Button(String(localized: "Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSaveConnection)
                .accessibilityIdentifier("ai-provider-save")
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 320)
        .task {
            await model.loadKey()
        }
        .onDisappear {
            model.cancelTasks()
        }
    }

    private func save() {
        guard model.canSaveConnection else { return }
        guard let current = slice.value.provider(withID: model.draft.id) else {
            model.saveError = String(localized: "This provider was removed.")
            return
        }
        guard let saved = model.connectionSave(current: current) else { return }
        if saved.connectionChanged {
            AIModelCatalog.shared.remove(providerID: current.id)
        }
        slice.value = slice.value.replacingProvider(saved.provider)
        AIProviderFactory.invalidateCache(for: current.id)
        AppEvents.shared.aiProviderSaved.send(current.id)
        onSaved(AIProviderConnectionSaved(connectionChanged: saved.connectionChanged, hasKey: saved.hasKey))
        dismiss()
    }
}
