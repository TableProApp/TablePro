//
//  InspectorFieldListView.swift
//  TablePro
//

import SwiftUI

/// The inspected row's fields.
///
/// A `List` and not a `Form`. Measured at the pane's width: `List` is lazy and stays lazy with rows
/// of differing heights, holding 336 subviews and about 135ms to first display whether the row has
/// 100 columns or 2000. `Form(.formStyle(.grouped))` builds every row eagerly, four subviews each,
/// and costs 525ms at 2000. A wide table would have paid that on every selection change.
internal struct InspectorFieldListView: View {
    internal let editState: MultiRowEditState
    internal let isEditable: Bool
    internal let databaseType: DatabaseType
    internal let userDefinedTypeScope: DatabaseScope?
    internal var onPopOut: ((FieldEditState, String, FieldEditorKind) -> Void)?

    @State private var searchText = ""
    @State private var showsModifiedOnly = false
    @State private var expandedFieldID: UUID?
    @FocusState private var focusedField: UUID?

    var body: some View {
        /// Resolved once per pass. `editState.fields` is observed, so the body runs on every
        /// keystroke in every field, and filtering inside `List` as well as inside the keyboard
        /// handlers walked the whole column list several times over for each one.
        let fields = visibleFields
        return VStack(spacing: 0) {
            filterBar
            Divider()
            if fields.isEmpty {
                emptyFilterState
            } else {
                fieldList(fields)
            }
        }
        .onChange(of: editState.fields.map(\.columnName)) {
            expandedFieldID = nil
            focusedField = nil
        }
    }

    // MARK: - Filtering

    /// Always visible rather than bolted above the list on some modes and not others. A row of two
    /// hundred columns is unreadable without it, and a control that is the only way to reach a
    /// field cannot be conditional.
    private var filterBar: some View {
        HStack(spacing: 6) {
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Search fields"),
                controlSize: .small,
                accessibilityIdentifier: "inspector-field-search"
            )
            Toggle(isOn: $showsModifiedOnly) {
                Label(String(localized: "Show edited fields only"), systemImage: "pencil.line")
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            .controlSize(.small)
            .help(String(localized: "Show edited fields only"))
            .disabled(!editState.hasEdits && !showsModifiedOnly)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var visibleFields: [FieldEditState] {
        editState.fields.filter { field in
            if showsModifiedOnly, !field.hasEdit, !field.hasCommittedEdit { return false }
            guard !searchText.isEmpty else { return true }
            if field.columnName.localizedCaseInsensitiveContains(searchText) { return true }
            return field.originalValue?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    private var emptyFilterState: some View {
        ContentUnavailableView(
            String(localized: "No Matching Fields"),
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text(String(localized: "No field matches the current filter"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private func fieldList(_ fields: [FieldEditState]) -> some View {
        List {
            ForEach(fields, id: \.id) { field in
                row(for: field)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 6))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onKeyPress(keys: [.tab]) { press in
            moveFocus(within: fields, forward: !press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(keys: ["n", "d"]) { press in
            guard press.modifiers.contains(.control), press.modifiers.contains(.option) else {
                return .ignored
            }
            return applyStateShortcut(press.key)
        }
    }

    @ViewBuilder
    private func row(for field: FieldEditState) -> some View {
        let kind = FieldEditorResolver.resolve(field: field)
        let editable = isEditable && !field.isServerOwned
        InspectorFieldRow(
            context: context(for: field, kind: kind, isEditable: editable),
            layout: InspectorFieldLayout.resolve(for: kind),
            kind: kind,
            isModified: field.hasEdit || field.hasCommittedEdit,
            isPrimaryKey: field.isPrimaryKey,
            isForeignKey: field.isForeignKey,
            databaseType: databaseType,
            isExpanded: expandedFieldID == field.id,
            onSetNull: { editState.setFieldToNull(at: field.columnIndex) },
            onSetDefault: { editState.setFieldToDefault(at: field.columnIndex) },
            onSetEmpty: { editState.setFieldToEmpty(at: field.columnIndex) },
            onSetFunction: { editState.setFieldToFunction(at: field.columnIndex, function: $0) },
            onToggleExpand: InspectorFieldLayout.resolve(for: kind) == .stacked
                ? { expandedFieldID = expandedFieldID == field.id ? nil : field.id }
                : nil,
            onPopOut: { onPopOut?(field, $0, kind) },
            focusedField: $focusedField,
            fieldID: field.id
        )
    }

    private func context(
        for field: FieldEditState,
        kind: FieldEditorKind,
        isEditable: Bool
    ) -> FieldEditorContext {
        let state = FieldValueState.resolve(field)
        return FieldEditorContext(
            columnName: field.columnName,
            columnType: field.columnTypeEnum,
            isLongText: field.isLongText,
            value: isEditable
                ? Binding(
                    get: { state.editableText },
                    set: { editState.updateField(at: field.columnIndex, value: $0) }
                )
                : .constant(state.editableText),
            originalValue: field.originalValue,
            valueState: state,
            isReadOnly: !isEditable,
            commitBytes: isEditable
                ? { editState.setFieldToBytes(at: field.columnIndex, data: $0) }
                : nil,
            editor: kind,
            allowsNullAndDefault: !field.isSchemaField,
            showsTypeBadge: !field.isSchemaField,
            userDefinedTypeScope: field.isSchemaField ? userDefinedTypeScope : nil
        )
    }

    // MARK: - Keyboard

    /// Tab has to be intercepted rather than left to AppKit. Measured: the key view loop inside a
    /// SwiftUI `List` has exactly one stop, so `nextValidKeyView` never leaves the field it starts
    /// in and Tab moved between fields not at all.
    private func moveFocus(within fields: [FieldEditState], forward: Bool) {
        guard !fields.isEmpty else { return }
        guard let current = focusedField, let index = fields.firstIndex(where: { $0.id == current }) else {
            focusedField = forward ? fields.first?.id : fields.last?.id
            return
        }
        let step = forward ? 1 : -1
        let next = (index + step + fields.count) % fields.count
        focusedField = fields[next].id
    }

    private func applyStateShortcut(_ key: KeyEquivalent) -> KeyPress.Result {
        guard isEditable,
              let focusedField,
              let field = editState.fields.first(where: { $0.id == focusedField }),
              !field.isServerOwned,
              !field.isSchemaField
        else { return .ignored }
        if key == "n" {
            editState.setFieldToNull(at: field.columnIndex)
        } else {
            editState.setFieldToDefault(at: field.columnIndex)
        }
        return .handled
    }
}
