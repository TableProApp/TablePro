//
//  UserTypeMembersPane.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// An enum's labels, a composite's fields or a domain's checks, as they will be after the queue
/// runs. Each row says what the queue does to it.
struct UserTypeMembersPane: View {
    @ObservedObject var model: UserTypeEditorModel
    let draft: UserTypeDraft
    let isDisabled: Bool
    let present: (UserTypeEditorSheet) -> Void

    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            switch model.kind {
            case .enumeration: labels
            case .composite: fields
            case .domain: constraints
            default: EmptyView()
            }
        }
    }

    // MARK: - Labels

    private var labels: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(draft.labels, selection: $selection) {
                TableColumn(String(localized: "Label")) { label in
                    Text(label.name)
                }
                TableColumn(String(localized: "Change")) { label in
                    status(for: label.origin, renamedFrom: label.isRenamed ? label.originalName : nil)
                }
                .width(min: 120, ideal: 180)
            }
            .accessibilityIdentifier("user-type-labels")
            Divider()
            HStack(spacing: 8) {
                Button {
                    present(.addLabel)
                } label: {
                    Label(String(localized: "Add Label"), systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Add Label"))
                .disabled(isDisabled || !model.support.addLabel)
                .accessibilityIdentifier("user-type-add-label")
                Button(String(localized: "Rename…")) {
                    if let label = selectedLabel { present(.renameLabel(label.name)) }
                }
                .disabled(isDisabled || selectedLabel == nil || !model.support.renameLabel)
                .help(model.support.renameLabel
                    ? String(localized: "Rename the selected label")
                    : String(localized: "This server cannot rename a label."))
                Text("A label cannot be removed or moved once it exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            .controlSize(.small)
            .padding(8)
        }
    }

    private var selectedLabel: UserTypeDraft.Label? {
        draft.labels.first { $0.id == selection }
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(draft.fields, selection: $selection) {
                TableColumn(String(localized: "Name")) { field in
                    Text(field.name).strikethrough(field.isDropped)
                }
                TableColumn(String(localized: "Type")) { field in
                    Text(field.type).strikethrough(field.isDropped)
                }
                TableColumn(String(localized: "Change")) { field in
                    fieldStatus(field)
                }
                .width(min: 120, ideal: 180)
            }
            .accessibilityIdentifier("user-type-fields")
            Divider()
            HStack(spacing: 8) {
                AddRemoveControlGroup(
                    addLabel: String(localized: "Add Field"),
                    removeLabel: String(localized: "Drop Field"),
                    canAdd: !isDisabled && model.support.addField,
                    canRemove: !isDisabled && canRemoveSelectedField,
                    addIdentifier: "user-type-add-field",
                    removeIdentifier: "user-type-drop-field",
                    onAdd: { present(.addField) },
                    onRemove: removeSelectedField
                )
                Button(String(localized: "Edit…")) {
                    if let field = selectedField { present(.editField(name: field.name, type: field.type)) }
                }
                .disabled(isDisabled || !canEditSelectedField)
                Spacer()
            }
            .controlSize(.small)
            .padding(8)
        }
    }

    private var selectedField: UserTypeDraft.Field? {
        draft.fields.first { $0.id == selection && !$0.isDropped }
    }

    private var canRemoveSelectedField: Bool {
        guard let field = selectedField else { return false }
        if case .added = field.origin { return true }
        return model.support.dropField
    }

    private var canEditSelectedField: Bool {
        selectedField != nil && (model.support.renameField || model.support.changeFieldType)
    }

    /// A field this queue added is taken back by removing its addition, not by queuing a drop.
    private func removeSelectedField() {
        guard let field = selectedField else { return }
        if case .added(let changeId) = field.origin {
            model.remove(changeId)
        } else {
            model.stage(.dropField(field.name))
        }
    }

    @ViewBuilder
    private func fieldStatus(_ field: UserTypeDraft.Field) -> some View {
        if field.isDropped {
            statusLabel(String(localized: "Dropped"), systemImage: "minus.circle", color: .red)
        } else if field.isRetyped, let original = field.originalType {
            statusLabel(String(format: String(localized: "Was %@"), original), systemImage: "pencil.circle", color: .orange)
        } else {
            status(for: field.origin, renamedFrom: field.isRenamed ? field.originalName : nil)
        }
    }

    // MARK: - Constraints

    private var constraints: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(draft.constraints, selection: $selection) {
                TableColumn(String(localized: "Name")) { constraint in
                    Text(constraint.name.isEmpty ? String(localized: "Named by the server") : constraint.name)
                        .foregroundStyle(constraint.name.isEmpty ? .secondary : .primary)
                        .strikethrough(constraint.isDropped)
                }
                TableColumn(String(localized: "Check")) { constraint in
                    Text(constraint.text).strikethrough(constraint.isDropped)
                }
                TableColumn(String(localized: "Change")) { constraint in
                    constraintStatus(constraint)
                }
                .width(min: 120, ideal: 180)
            }
            .accessibilityIdentifier("user-type-constraints")
            Divider()
            HStack(spacing: 8) {
                AddRemoveControlGroup(
                    addLabel: String(localized: "Add Check"),
                    removeLabel: String(localized: "Drop Constraint"),
                    canAdd: !isDisabled && model.support.addCheck,
                    canRemove: !isDisabled && canRemoveSelectedConstraint,
                    addIdentifier: "user-type-add-check",
                    removeIdentifier: "user-type-drop-constraint",
                    onAdd: { present(.addCheck) },
                    onRemove: removeSelectedConstraint
                )
                Button(String(localized: "Validate")) {
                    if let constraint = selectedConstraint { model.stage(.validateConstraint(constraint.name)) }
                }
                .disabled(isDisabled || !canValidateSelectedConstraint)
                .help(String(localized: "Check the values already stored against the selected constraint"))
                Spacer()
            }
            .controlSize(.small)
            .padding(8)
        }
    }

    private var selectedConstraint: UserTypeDraft.Constraint? {
        draft.constraints.first { $0.id == selection && !$0.isDropped }
    }

    private var canRemoveSelectedConstraint: Bool {
        guard let constraint = selectedConstraint else { return false }
        if case .added = constraint.origin { return true }
        return model.support.dropConstraint
    }

    private var canValidateSelectedConstraint: Bool {
        guard let constraint = selectedConstraint, case .existing = constraint.origin else { return false }
        return !constraint.isValidated && model.support.validateConstraint
    }

    private func removeSelectedConstraint() {
        guard let constraint = selectedConstraint else { return }
        if case .added(let changeId) = constraint.origin {
            model.remove(changeId)
        } else {
            model.stage(.dropConstraint(constraint.name))
        }
    }

    @ViewBuilder
    private func constraintStatus(_ constraint: UserTypeDraft.Constraint) -> some View {
        if constraint.isDropped {
            statusLabel(String(localized: "Dropped"), systemImage: "minus.circle", color: .red)
        } else if constraint.isValidationQueued {
            statusLabel(String(localized: "Validated on save"), systemImage: "checkmark.circle", color: .orange)
        } else if case .added = constraint.origin {
            status(for: constraint.origin, renamedFrom: nil)
        } else if !constraint.isValidated {
            Text("Not validated").foregroundStyle(.secondary)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private func status(for origin: UserTypeDraft.Origin, renamedFrom original: String?) -> some View {
        if case .added = origin {
            statusLabel(String(localized: "New"), systemImage: "plus.circle", color: .green)
        } else if let original {
            statusLabel(String(format: String(localized: "Was “%@”"), original), systemImage: "pencil.circle", color: .orange)
        }
    }

    private func statusLabel(_ text: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
    }
}
