import SwiftUI

struct SlashCommandsPage: View {
    private struct Editing: Identifiable {
        let command: CustomSlashCommand
        let isNew: Bool

        var id: UUID { command.id }
    }

    @ObservedObject var storage: CustomSlashCommandStorage
    @State private var editing: Editing?
    @State private var pendingDelete: CustomSlashCommand?

    var body: some View {
        Form {
            Section {
                if storage.commands.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No slash commands")
                        Text("Add one to reuse a prompt in the chat.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    ForEach(storage.commands) { command in
                        row(command)
                    }
                }
                SettingsHelpRow("Type / in the chat to run one. A template can use {{query}}, {{schema}}, {{database}} and {{body}}.")
            } footer: {
                SettingsSectionActions {
                    Button("Add Command…") {
                        editing = Editing(command: CustomSlashCommand(), isNew: true)
                    }
                    .accessibilityIdentifier("slash-command-add")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.slashCommands.pageIdentifier)
        .sheet(item: $editing) { editing in
            CustomSlashCommandEditorSheet(
                initial: editing.command,
                isCreating: editing.isNew,
                isDuplicate: { name in storage.isDuplicate(name, excluding: editing.isNew ? nil : editing.command.id) },
                onSave: { command in save(command, isNew: editing.isNew) },
                onDelete: editing.isNew ? nil : { storage.delete(id: editing.command.id) }
            )
        }
        .alert(
            pendingDelete.map { String(format: String(localized: "Delete “/%@”?"), $0.name) } ?? "",
            isPresented: deleteBinding,
            presenting: pendingDelete
        ) { command in
            Button(String(localized: "Delete"), role: .destructive) {
                storage.delete(id: command.id)
                pendingDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingDelete = nil
            }
        } message: { _ in
            Text("The command is removed from this Mac and from every Mac that syncs settings. This cannot be undone.")
        }
    }

    private func row(_ command: CustomSlashCommand) -> some View {
        SettingsRecordRow(
            title: "/\(command.name)",
            subtitle: command.description.isEmpty ? nil : command.description
        )
        .infoButton(
            onEdit: { editing = Editing(command: command, isNew: false) },
            removal: .delete { pendingDelete = command },
            identifier: "slash-command-edit-\(command.id.uuidString)"
        )
        .accessibilityIdentifier("slash-command-\(command.id.uuidString)")
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    // Returns the error to show in the sheet, or nil once the command is stored.
    private func save(_ command: CustomSlashCommand, isNew: Bool) -> String? {
        do {
            if isNew {
                try storage.add(command)
            } else {
                try storage.update(command)
            }
            editing = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct CustomSlashCommandEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CustomSlashCommand
    @State private var saveError: String?
    @State private var confirmsDelete = false

    private let isCreating: Bool
    private let isDuplicate: (String) -> Bool
    private let onSave: (CustomSlashCommand) -> String?
    private let onDelete: (() -> Void)?

    init(
        initial: CustomSlashCommand,
        isCreating: Bool,
        isDuplicate: @escaping (String) -> Bool,
        onSave: @escaping (CustomSlashCommand) -> String?,
        onDelete: (() -> Void)?
    ) {
        _draft = State(initialValue: initial)
        self.isCreating = isCreating
        self.isDuplicate = isDuplicate
        self.onSave = onSave
        self.onDelete = onDelete
    }

    // A leading slash is what the chat types, not part of the name.
    static func normalizedName(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    private var name: String {
        Self.normalizedName(draft.name)
    }

    private var duplicates: Bool {
        !name.isEmpty && isDuplicate(name)
    }

    private var canSave: Bool {
        var normalized = draft
        normalized.name = name
        return normalized.isValid && !duplicates
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(text: $draft.name, prompt: Text(verbatim: "summarize")) {
                        Text("Name")
                        nameNotice
                    }
                    .accessibilityIdentifier("slash-command-name")
                    TextField(text: $draft.description, prompt: Text("Optional")) {
                        Text("Description")
                    }
                    .accessibilityIdentifier("slash-command-description")
                }
                Section {
                    TextEditor(text: $draft.promptTemplate)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .accessibilityLabel(String(localized: "Prompt template"))
                        .accessibilityIdentifier("slash-command-template")
                    SettingsHelpRow(
                        """
                        Use {{query}} for the current editor query, {{schema}} for the active schema, \
                        {{database}} for the active database name, and {{body}} for any text typed after the command.
                        """
                    )
                } header: {
                    Text("Prompt Template")
                }
            }
            .formStyle(.grouped)

            Divider()

            DialogFooter {
                if onDelete != nil {
                    Button(String(localized: "Delete Command…"), role: .destructive) {
                        confirmsDelete = true
                    }
                    .accessibilityIdentifier("slash-command-delete")
                }
            } actions: {
                Button(String(localized: "Cancel"), role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isCreating ? String(localized: "Add") : String(localized: "Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityIdentifier("slash-command-save")
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 400)
        .alert(
            String(localized: "Couldn't Save the Command"),
            isPresented: saveErrorBinding,
            presenting: saveError
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) {
                saveError = nil
            }
        } message: { message in
            Text(verbatim: message)
        }
        .alert(
            String(format: String(localized: "Delete “/%@”?"), name),
            isPresented: $confirmsDelete
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("The command is removed from this Mac and from every Mac that syncs settings. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var nameNotice: some View {
        if duplicates {
            NoticeLabel(String(format: String(localized: "A command named “/%@” already exists."), name))
        } else if SlashCommand.isBuiltIn(name: name) {
            NoticeLabel(String(
                format: String(localized: "/%@ is a built-in command. Typing it runs the built-in; this one runs only from the command menu."),
                name.lowercased()
            ))
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private func save() {
        var command = draft
        command.name = name
        command.description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.isValid, !duplicates else { return }
        saveError = onSave(command)
    }
}
