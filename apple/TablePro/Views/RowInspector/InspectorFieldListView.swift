//
//  InspectorFieldListView.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI

// A List, not a Form: measured lazy at 336 subviews and ~135ms for 100 or 2000 columns; a grouped Form costs 525ms at 2000.
internal struct InspectorFieldListView: View {
    @ObservedObject internal var editState: MultiRowEditState
    internal let isEditable: Bool
    internal let databaseType: DatabaseType
    internal var offersDatabaseValues = true

    private var offersFieldRemoval: Bool {
        offersDatabaseValues && PluginManager.shared.supportsFieldRemoval(for: databaseType)
    }
    internal var onPopOut: ((FieldEditState, String, FieldEditorKind) -> Void)?

    @State private var searchText = ""
    @State private var showsModifiedOnly = false
    @StateObject private var tabStops = InspectorTabStopRegistry()
    @FocusState private var focusedField: UUID?

    var body: some View {
        // Once per pass: the body runs on every keystroke, and filtering per use walked every column several times.
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
            focusedField = nil
        }
    }

    // MARK: - Filtering

    // Always visible: on a row of two hundred columns it is the only way to reach a field.
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

    // One answer for the editor, the value menu and the shortcuts. PHP-serialized and decoded binary values have no writer back.
    internal static func isFieldEditable(
        _ field: FieldEditState,
        kind: FieldEditorKind,
        rowIsEditable: Bool
    ) -> Bool {
        guard rowIsEditable, !field.isServerOwned else { return false }
        switch kind {
        case .phpSerialized, .binaryValue:
            return false
        case .json, .image, .geometry, .blobHex, .boolean, .enumPicker, .setPicker, .arrayElements, .vector,
             .multiLine, .singleLine:
            return true
        }
    }

    // Rows that disagree carry an edit made elsewhere as `hasCommittedEdit`, with no pending value.
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
        // `.plain`, not `.inset`: the inset style spends 16pt per side before `listRowInsets`, which no inset can undo.
        .listStyle(.plain)
        .splitItemGlassBackground()
        .modifier(InspectorFieldKeyShortcuts(
            moveFocus: { forward in moveFocus(within: fields, forward: forward) },
            applyStateShortcut: applyStateShortcut
        ))
    }

    @ViewBuilder
    private func row(for field: FieldEditState) -> some View {
        let kind = FieldEditorResolver.resolve(field: field)
        let editable = Self.isFieldEditable(field, kind: kind, rowIsEditable: isEditable)
        let commands = editState.setValueCommands(for: field, isWritable: editable && offersDatabaseValues)
        InspectorFieldRow(
            context: context(for: field, kind: kind, isEditable: editable),
            kind: kind,
            isModified: field.hasEdit || field.hasCommittedEdit,
            isPrimaryKey: field.isPrimaryKey,
            isForeignKey: field.isForeignKey,
            isExpanded: editState.expandedColumn == field.columnIndex,
            commands: commands,
            isPendingExpression: field.isPendingExpression,
            onSetValue: { editState.setValue($0, at: field.columnIndex) },
            onRemoveField: offersFieldRemoval ? { editState.removeField(at: field.columnIndex) } : nil,
            onToggleExpand: FieldEditorContent.canExpand(kind: kind, state: FieldValueState.resolve(field))
                ? { editState.toggleExpansion(ofColumn: field.columnIndex) }
                : nil,
            onPopOut: { onPopOut?(field, $0, kind) },
            onTabStopChange: { [tabStops] in tabStops.record($0, for: field.id) },
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
            // Reads the store, not `state`: a copy from this render made editors put back the value just replaced (#3051).
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
            allowsNullAndDefault: offersDatabaseValues,
            isBinaryValue: field.isBinaryValue
        )
    }

    // MARK: - Keyboard

    // A List's key view loop has one stop, measured. Ignored at either end so focus leaves the list instead of wrapping.
    private func moveFocus(within fields: [FieldEditState], forward: Bool) -> KeyPressResultCompat {
        guard !fields.isEmpty else { return .ignored }
        let order = fields.map(\.id)
        tabStops.forget(allBut: order)
        // With Full Keyboard Access on, the controls of a field showing a map are key views.
        let skipped = NSApplication.shared.isFullKeyboardAccessEnabled ? [] : tabStops.fieldsWithoutTabStop
        let destination = Self.focusDestination(from: focusedField, in: order, forward: forward, skipping: skipped)
        focusedField = destination
        return destination == nil ? .ignored : .handled
    }

    // Nil lets the key leave the list. A field with nothing to focus is passed over.
    internal static func focusDestination(
        from current: UUID?,
        in order: [UUID],
        forward: Bool,
        skipping fieldsWithoutTabStop: Set<UUID>
    ) -> UUID? {
        let candidates: [UUID]
        if let current, let index = order.firstIndex(of: current) {
            candidates = forward ? Array(order[(index + 1)...]) : Array(order[..<index].reversed())
        } else {
            candidates = forward ? order : order.reversed()
        }
        return candidates.first { !fieldsWithoutTabStop.contains($0) }
    }

    private func applyStateShortcut(_ key: Character) -> KeyPressResultCompat {
        guard isEditable,
              offersDatabaseValues,
              let focusedField,
              let field = editState.fields.first(where: { $0.id == focusedField }),
              Self.isFieldEditable(field, kind: FieldEditorResolver.resolve(field: field), rowIsEditable: isEditable),
              let command = Self.stateShortcutCommand(
                  for: key, offered: editState.setValueCommands(for: field, isWritable: true)
              )
        else { return .ignored }
        editState.setValue(command, at: field.columnIndex)
        return .handled
    }

    // Only what the field's menu offers; otherwise the key goes on rather than staging a NULL the column refuses.
    internal static func stateShortcutCommand(for key: Character, offered: [SetValueCommand]) -> SetValueCommand? {
        let command: SetValueCommand
        switch key {
        case "n": command = .null
        case "d": command = .defaultValue
        default: return nil
        }
        return offered.contains(command) ? command : nil
    }
}

// Fields with nothing Tab can land on. Publishes nothing, so a field reporting in does not redraw the list.
@MainActor
internal final class InspectorTabStopRegistry: ObservableObject {
    internal private(set) var fieldsWithoutTabStop: Set<UUID> = []

    internal func record(_ hasTabStop: Bool, for fieldID: UUID) {
        if hasTabStop {
            fieldsWithoutTabStop.remove(fieldID)
        } else {
            fieldsWithoutTabStop.insert(fieldID)
        }
    }

    // Field ids are reissued on every selection change.
    internal func forget(allBut fieldIDs: [UUID]) {
        fieldsWithoutTabStop.formIntersection(fieldIDs)
    }
}

// `onKeyPress` is macOS 14. On 13 Tab still moves focus through the responder chain; the field's menu covers the shortcuts.
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

// Mirrors macOS 14's `KeyPress.Result`, so the handlers can be declared outside the check.
internal enum KeyPressResultCompat {
    case handled
    case ignored

    @available(macOS 14.0, *)
    var resolved: KeyPress.Result {
        self == .handled ? .handled : .ignored
    }
}
