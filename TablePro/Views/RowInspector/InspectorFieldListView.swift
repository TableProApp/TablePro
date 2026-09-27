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
    @ObservedObject internal var editState: MultiRowEditState
    internal let isEditable: Bool
    internal let databaseType: DatabaseType
    internal let userDefinedTypeScope: DatabaseScope?
    internal var offersDatabaseValues = true

    private var offersFieldRemoval: Bool {
        offersDatabaseValues && PluginManager.shared.supportsFieldRemoval(for: databaseType)
    }
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
        .onChange(of: editState.fields.map(\.columnName)) { _ in
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
            .disabled(!hasAnyModification && !showsModifiedOnly)
        }
        .padding(.horizontal, InspectorMetrics.horizontalInset)
        .padding(.vertical, 5)
    }

    /// Whether this field accepts a change at all.
    ///
    /// One answer, read by the editor, by the value menu and by the keyboard shortcuts alike. A
    /// PHP-serialized value cannot be round-tripped without PHP, so the field is presented but never
    /// mutated: Set NULL, Set DEFAULT, Set EMPTY and the SQL functions would each overwrite the
    /// serialized payload with something the app cannot rebuild.
    internal static func isFieldEditable(
        _ field: FieldEditState,
        kind: FieldEditorKind,
        rowIsEditable: Bool
    ) -> Bool {
        guard rowIsEditable, !field.isServerOwned else { return false }
        return kind != .phpSerialized
    }

    /// A structure row's edits are recorded by its own grid, so `hasEdits` stays false while
    /// `hasCommittedEdit` is true. Gating on pending edits alone left the filter permanently
    /// unusable on exactly the rows it lists as modified.
    private var hasAnyModification: Bool {
        editState.fields.contains { $0.hasEdit || $0.hasCommittedEdit }
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
        UnavailableStateView(
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
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: InspectorMetrics.listRowLeadingCorrection,
                        bottom: 0,
                        trailing: InspectorMetrics.listRowTrailingCorrection
                    ))
            }
        }
        /// `.plain`, not `.inset`: the inset style spends a hard 16pt per side before any
        /// `listRowInsets` is consulted, so the pane's content sat at 24pt while its own header sat
        /// at 10. `.plain` lands at half of `intercellSpacing` and can be corrected onto the edge.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .modifier(InspectorFieldKeyShortcuts(
            moveFocus: { forward in moveFocus(within: fields, forward: forward) },
            applyStateShortcut: applyStateShortcut
        ))
    }

    @ViewBuilder
    private func row(for field: FieldEditState) -> some View {
        let kind = FieldEditorResolver.resolve(field: field)
        let editable = Self.isFieldEditable(field, kind: kind, rowIsEditable: isEditable)
        InspectorFieldRow(
            context: context(for: field, kind: kind, isEditable: editable),
            layout: InspectorFieldLayout.resolve(for: kind, isSchemaField: field.isSchemaField),
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
            onRemoveField: offersFieldRemoval && !field.isSchemaField
                ? { editState.removeField(at: field.columnIndex) }
                : nil,
            onToggleExpand: FieldEditorContent.canExpand(kind: kind, state: FieldValueState.resolve(field))
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
        let columnIndex = field.columnIndex
        return FieldEditorContext(
            columnName: field.columnName,
            columnType: field.columnTypeEnum,
            isLongText: field.isLongText,
            /// The getter reads the store, not the `state` resolved above. That value is a copy
            /// taken when this context was built, so a getter closing over it answers whatever the
            /// field held during that render, and an `onChange` action, which belongs to the
            /// render that registered it, is a render behind again. An editor comparing its text
            /// against that answer sees the value it had just replaced and puts it back (#3051).
            value: isEditable
                ? Binding(
                    get: { editState.currentText(at: columnIndex) },
                    set: { editState.updateField(at: columnIndex, value: $0) }
                )
                : .constant(state.editableText),
            originalValue: field.originalValue,
            valueState: state,
            isReadOnly: !isEditable,
            commitBytes: isEditable
                ? { editState.setFieldToBytes(at: field.columnIndex, data: $0) }
                : nil,
            editor: kind,
            allowsNullAndDefault: offersDatabaseValues && !field.isSchemaField,
            showsTypeBadge: !field.isSchemaField,
            userDefinedTypeScope: field.isSchemaField ? userDefinedTypeScope : nil
        )
    }

    // MARK: - Keyboard

    /// Tab has to be intercepted rather than left to AppKit. Measured: the key view loop inside a
    /// SwiftUI `List` has exactly one stop, so `nextValidKeyView` never leaves the field it starts
    /// in and Tab moved between fields not at all.
    /// Handled while there is another field to reach, ignored at either end so the key falls
    /// through and focus can leave the list for the search field, the filter and the view-mode
    /// control. Wrapping around instead trapped the keyboard inside the row for good.
    private func moveFocus(within fields: [FieldEditState], forward: Bool) -> KeyPressResultCompat {
        guard !fields.isEmpty else { return .ignored }
        guard let current = focusedField, let index = fields.firstIndex(where: { $0.id == current }) else {
            focusedField = forward ? fields.first?.id : fields.last?.id
            return .handled
        }
        let next = forward ? index + 1 : index - 1
        guard fields.indices.contains(next) else {
            focusedField = nil
            return .ignored
        }
        focusedField = fields[next].id
        return .handled
    }

    private func applyStateShortcut(_ key: Character) -> KeyPressResultCompat {
        guard isEditable,
              offersDatabaseValues,
              let focusedField,
              let field = editState.fields.first(where: { $0.id == focusedField }),
              !field.isSchemaField,
              Self.isFieldEditable(field, kind: FieldEditorResolver.resolve(field: field), rowIsEditable: isEditable)
        else { return .ignored }
        if key == "n" {
            editState.setFieldToNull(at: field.columnIndex)
        } else {
            editState.setFieldToDefault(at: field.columnIndex)
        }
        return .handled
    }
}

/// `onKeyPress` is macOS 14, and `KeyPress` cannot appear outside the check, so the handlers
/// are gated as a pair. Tab still moves focus on macOS 13 through the responder chain; what is
/// lost there is the Control-Option state shortcut, which the field's own menu also offers.
private struct InspectorFieldKeyShortcuts: ViewModifier {
    let moveFocus: (Bool) -> KeyPressResultCompat
    let applyStateShortcut: (Character) -> KeyPressResultCompat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(keys: [.tab]) { press in
                    moveFocus(!press.modifiers.contains(.shift)).resolved
                }
                .onKeyPress(keys: ["n", "d"]) { press in
                    guard press.modifiers.contains(.control), press.modifiers.contains(.option) else {
                        return .ignored
                    }
                    return applyStateShortcut(press.characters.first ?? " ").resolved
                }
        } else {
            content
        }
    }
}

/// Mirrors `KeyPress.Result`, which is macOS 14, so the handlers can be declared outside the check.
internal enum KeyPressResultCompat {
    case handled
    case ignored

    @available(macOS 14.0, *)
    var resolved: KeyPress.Result {
        self == .handled ? .handled : .ignored
    }
}
