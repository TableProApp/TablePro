//
//  PluginFieldRow.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

// One plugin-declared field, in the control its kind asks for. The engine has already decided that it shows.
struct PluginFieldRow: View {
    private let fieldID: String
    @ObservedObject private var store: ConnectionEditorStore
    private let title: String?

    @State private var isEdited = false

    // `title` replaces the plugin's label where the facet shows it under a header that already says it.
    init(fieldID: String, store: ConnectionEditorStore, title: String? = nil) {
        self.fieldID = fieldID
        self.store = store
        self.title = title
    }

    private var row: EditorRow { .plugin(fieldID: fieldID) }

    var body: some View {
        if let field = store.pluginField(fieldID), let kind = store.pluginFieldKind(fieldID) {
            control(field, kind)
        }
    }

    @ViewBuilder
    private func control(_ field: ConnectionField, _ kind: PluginFieldKind) -> some View {
        let value = store.pluginFieldBinding(fieldID)
        let name = title ?? field.label
        let prompt = field.placeholder.isEmpty ? nil : field.placeholder
        switch kind {
        case .text:
            EditorTextRow(name, text: value, prompt: prompt, row: row, store: store)
        case .secure:
            EditorSecureRow(name, text: value, prompt: prompt, row: row, store: store)
        case .number:
            EditorTextRow(name, text: wholeNumberBinding(value), prompt: prompt, row: row, store: store)
        case .dropdown(let options):
            Picker(selection: trackingEdits(value)) {
                ForEach(options, id: \.value) { option in
                    Text(verbatim: option.label).tag(option.value)
                }
            } label: {
                label(field)
            }
            .accessibilityIdentifier(row.accessibilityIdentifier)
        case .toggle:
            Toggle(isOn: toggleBinding(value)) {
                label(field)
            }
            .accessibilityIdentifier(row.accessibilityIdentifier)
        case .stepper(let range):
            LabeledContent {
                ConnectionStepperField(
                    label: name,
                    range: ConnectionField.IntRange(range),
                    defaultValue: field.defaultValue,
                    value: trackingEdits(value)
                )
                .labelsHidden()
                .accessibilityIdentifier(row.accessibilityIdentifier)
            } label: {
                label(field)
            }
        case .hostList:
            LabeledContent {
                HostListFieldRow(
                    label: name,
                    placeholder: field.placeholder,
                    defaultPort: store.traits.defaultPort,
                    value: trackingEdits(value)
                )
                .labelsHidden()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(row.accessibilityIdentifier)
            } label: {
                label(field)
            }
        case .attachedDatabases:
            listEditor {
                AttachedDatabaseListEditor(value: trackingEdits(value), databaseType: store.draft.type)
            }
        case .loadableExtensions:
            listEditor {
                LoadableExtensionListEditor(value: trackingEdits(value))
            }
        case .localDatabaseFile:
            EditorDatabaseFileRow(
                name,
                path: value,
                prompt: prompt,
                row: row,
                store: store,
                chooseIdentifier: "\(row.accessibilityIdentifier)-choose",
                newIdentifier: "\(row.accessibilityIdentifier)-new"
            )
        case .filePath:
            EditorPathRow(name, path: value, prompt: prompt, row: row, store: store) {
                await EditorFilePanel.chooseFile(in: EditorFilePanel.window(for: store), currentPath: value.wrappedValue)
            }
        case .awsProfile:
            LabeledContent {
                SuggestionComboBox(
                    suggestions: Self.awsProfiles,
                    placeholder: field.placeholder,
                    accessibilityLabel: name,
                    accessibilityIdentifier: row.accessibilityIdentifier,
                    value: trackingEdits(value)
                )
            } label: {
                label(field)
            }
        }
    }

    private func label(_ field: ConnectionField) -> EditorRowLabel {
        EditorRowLabel(title ?? field.label, row: row, store: store, isEdited: isEdited)
    }

    // A list is the whole row, titled by its section header, so its issue sits under it in the same row.
    private func listEditor<Editor: View>(@ViewBuilder _ editor: () -> Editor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            editor()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(row.accessibilityIdentifier)
            if let issue = EditorIssueVisibility.issue(for: row, in: store, isEdited: isEdited) {
                NoticeLabel(issue.message, severity: issue.severity == .error ? .error : .warning)
            }
        }
    }

    private func trackingEdits(_ binding: Binding<String>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                guard newValue != binding.wrappedValue else { return }
                isEdited = true
                binding.wrappedValue = newValue
            }
        )
    }

    private func toggleBinding(_ binding: Binding<String>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue == "true" },
            set: { newValue in
                isEdited = true
                binding.wrappedValue = newValue ? "true" : "false"
            }
        )
    }

    // The raw text lands first so a rejected keystroke still changes the value and the field redraws without it.
    private func wholeNumberBinding(_ binding: Binding<String>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                let sanitized = ConnectionField.IntRange.wholeNumbers.fieldText(sanitizing: newValue)
                if sanitized != newValue {
                    binding.wrappedValue = sanitized
                }
            }
        )
    }

    private static func awsProfiles() -> [String] {
        AWSConfigFile.discoverProfiles(
            configContents: AWSConfigFile.readFile(AWSConfigFile.defaultConfigPath),
            credentialsContents: AWSConfigFile.readFile(AWSConfigFile.defaultCredentialsPath)
        )
    }
}
