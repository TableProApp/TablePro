//
//  UserTypeMemberSheet.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// Adds or edits one label, field or check. Nothing runs here: the button queues the change, and
/// the problem the queue would report for it is shown before it is queued.
struct UserTypeMemberSheet: View {
    @Environment(\.dismiss) private var dismiss

    let sheet: UserTypeEditorSheet
    @ObservedObject var model: UserTypeEditorModel
    let databaseType: DatabaseType

    @State private var text = ""
    @State private var secondText = ""
    @State private var placement: Placement = .end
    @State private var anchor = ""
    @State private var validatesStoredValues = true

    private enum Placement: Hashable {
        case end
        case before
        case after
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)
            Form {
                fields
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            Divider()
            DialogFooter {
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    for change in changes { model.stage(change) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changes.isEmpty || problem != nil)
                .accessibilityIdentifier("user-type-member-confirm")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 440)
        .onAppear(perform: seed)
    }

    private var title: String {
        switch sheet {
        case .addLabel: String(localized: "Add Label")
        case .renameLabel: String(localized: "Rename Label")
        case .addField: String(localized: "Add Field")
        case .editField: String(localized: "Edit Field")
        case .addCheck: String(localized: "Add Check")
        }
    }

    private var confirmTitle: String {
        switch sheet {
        case .renameLabel: String(localized: "Rename")
        case .editField: String(localized: "Done")
        case .addLabel, .addField, .addCheck: String(localized: "Add")
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch sheet {
        case .addLabel:
            TextField(String(localized: "Label"), text: $text)
                .accessibilityIdentifier("user-type-label-name")
            if model.support.placeLabel, !labels.isEmpty {
                Picker(String(localized: "Position"), selection: $placement) {
                    Text("At the End").tag(Placement.end)
                    Text("Before").tag(Placement.before)
                    Text("After").tag(Placement.after)
                }
                if placement != .end {
                    Picker(String(localized: "Label"), selection: $anchor) {
                        ForEach(labels, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
        case .renameLabel(let label):
            LabeledContent(String(localized: "Label")) { Text(label) }
            TextField(String(localized: "New Name"), text: $text)
                .accessibilityIdentifier("user-type-label-new-name")
        case .addField, .editField:
            TextField(String(localized: "Name"), text: $text)
                .disabled(!canRenameField)
                .accessibilityIdentifier("user-type-field-name")
            LabeledContent(String(localized: "Type")) {
                SuggestionComboBox(
                    suggestions: { typeSuggestions },
                    placeholder: "integer",
                    accessibilityLabel: String(localized: "Type"),
                    accessibilityIdentifier: "user-type-field-type",
                    value: $secondText
                )
                .disabled(!canRetypeField)
            }
        case .addCheck:
            TextField(String(localized: "Name"), text: $text, prompt: Text("Named by the server"))
                .accessibilityIdentifier("user-type-check-name")
            TextField(String(localized: "Expression"), text: $secondText, prompt: Text(verbatim: "VALUE > 0"))
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("user-type-check-expression")
            Toggle(String(localized: "Check the values already stored"), isOn: $validatesStoredValues)
                .disabled(!model.support.addUnvalidatedCheck)
                .help(String(localized: "Turn off to add the check now and validate the stored values later."))
        }
    }

    private var labels: [String] {
        model.projection?.draft.labels.map(\.name) ?? []
    }

    private var canRenameField: Bool {
        if case .editField = sheet { return model.support.renameField }
        return true
    }

    private var canRetypeField: Bool {
        if case .editField = sheet { return model.support.changeFieldType }
        return true
    }

    private var typeSuggestions: [String] {
        PluginManager.shared.columnTypesByCategory(for: databaseType).values.flatMap { $0 }.sorted()
    }

    private func seed() {
        switch sheet {
        case .editField(let name, let type):
            text = name
            secondText = type
        case .renameLabel(let label):
            text = label
        case .addLabel:
            anchor = labels.last ?? ""
        default:
            break
        }
    }

    /// What the sheet queues: an edited field can be renamed and retyped at once, retyped under its
    /// old name first so each statement names the field as it stands.
    private var changes: [PluginUserDefinedTypeChange] {
        let name = text.trimmingCharacters(in: .whitespaces)
        let other = secondText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sheet {
        case .addLabel:
            guard !text.isEmpty else { return [] }
            let placement: PluginEnumLabelPlacement? = switch self.placement {
            case .end: nil
            case .before: anchor.isEmpty ? nil : PluginEnumLabelPlacement(anchor: anchor, placesBefore: true)
            case .after: anchor.isEmpty ? nil : PluginEnumLabelPlacement(anchor: anchor, placesBefore: false)
            }
            return [.addEnumLabel(text, placement: placement)]
        case .renameLabel(let label):
            guard !text.isEmpty, text != label else { return [] }
            return [.renameEnumLabel(from: label, to: text)]
        case .addField:
            guard !name.isEmpty, !other.isEmpty else { return [] }
            return [.addField(PluginUserDefinedTypeField(name: name, type: other))]
        case .editField(let original, let originalType):
            var result: [PluginUserDefinedTypeChange] = []
            if !other.isEmpty, other != originalType { result.append(.changeFieldType(field: original, type: other)) }
            if !name.isEmpty, name != original { result.append(.renameField(from: original, to: name)) }
            return result
        case .addCheck:
            guard !other.isEmpty else { return [] }
            return [.addCheck(
                PluginUserDefinedTypeCheck(name: name.isEmpty ? nil : name, expression: other),
                validatesExistingValues: validatesStoredValues || !model.support.addUnvalidatedCheck
            )]
        }
    }

    private var problem: String? {
        model.problem(staging: changes)
    }
}
