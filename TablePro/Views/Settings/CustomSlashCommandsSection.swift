//
//  CustomSlashCommandsSection.swift
//  TablePro
//

import SwiftUI

struct CustomSlashCommandsSection: View {
    @Bindable var storage: CustomSlashCommandStorage
    @State private var editing: CustomSlashCommand?
    @State private var isCreating = false
    @State private var saveError: String?

    var body: some View {
        Section {
            if storage.commands.isEmpty {
                emptyState
            } else {
                ForEach(storage.commands) { command in
                    row(for: command)
                }
            }
            HStack {
                Spacer()
                Button {
                    editing = CustomSlashCommand()
                    isCreating = true
                } label: {
                    Label(String(localized: "Add Command"), systemImage: "plus")
                }
                .controlSize(.small)
            }
        } header: {
            Text(String(localized: "Custom Slash Commands"))
        } footer: {
            Text(String(
                localized: "Create your own slash commands. Use {{query}}, {{schema}}, {{database}}, or {{body}} in the template to insert chat context at runtime."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { command in
            CustomSlashCommandEditorSheet(
                initial: command,
                isCreating: isCreating,
                onSave: { updated in
                    do {
                        if isCreating {
                            try storage.add(updated)
                        } else {
                            try storage.update(updated)
                        }
                        editing = nil
                        isCreating = false
                    } catch {
                        saveError = error.localizedDescription
                    }
                },
                onCancel: {
                    editing = nil
                    isCreating = false
                }
            )
        }
        .alert(
            String(localized: "Cannot Save Command"),
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            ),
            presenting: saveError
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) { saveError = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Text(String(localized: "No custom commands yet."))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row(for command: CustomSlashCommand) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("/\(command.name)")
                    .font(.body)
                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(String(localized: "Edit")) {
                editing = command
                isCreating = false
            }
            .controlSize(.small)
            Button(role: .destructive) {
                storage.delete(id: command.id)
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
        }
    }
}

struct CustomSlashCommandEditorSheet: View {
    @State var draft: CustomSlashCommand
    let isCreating: Bool
    let onSave: (CustomSlashCommand) -> Void
    let onCancel: () -> Void

    init(
        initial: CustomSlashCommand,
        isCreating: Bool,
        onSave: @escaping (CustomSlashCommand) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: initial)
        self.isCreating = isCreating
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent(String(localized: "Name")) {
                        TextField("review", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent(String(localized: "Description")) {
                        TextField(String(localized: "Optional one-line description"), text: $draft.description)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Section {
                    TextEditor(text: $draft.promptTemplate)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                } header: {
                    Text(String(localized: "Prompt template"))
                } footer: {
                    Text(String(localized: """
                        Use {{query}} for the current editor query, {{schema}} for the active schema, \
                        {{database}} for the active database name, and {{body}} for any text typed \
                        after the command.
                        """))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isCreating ? String(localized: "Add") : String(localized: "Save")) {
                    onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
