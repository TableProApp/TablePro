//
//  ArrayFieldEditorView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// The row inspector's editor for an array column.
///
/// It follows `SetPickerView`: a value built structurally cannot be typed into the field, so the
/// row shows the stored literal and opens the real editor in a popover that commits once. Writing
/// through on every keystroke would rebuild the literal from a half-finished element, and NULL and
/// DEFAULT would have nowhere to live, since the field's binding carries a `String` and neither is
/// one.
internal struct ArrayFieldEditorView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    internal let context: FieldEditorContext
    internal let elementEditor: ArrayElementEditor
    internal let allowedValues: [String]
    internal var onSetNull: (() -> Void)?
    internal var onSetDefault: (() -> Void)?

    @State private var isEditorPresented = false

    var body: some View {
        Menu {
            Button {
                isEditorPresented = true
            } label: {
                Text(context.isReadOnly ? "View Elements…" : "Edit Elements…")
            }
            if context.canMutate, onSetNull != nil || onSetDefault != nil {
                Divider()
                if let onSetNull {
                    Button("Set NULL", action: onSetNull)
                }
                if let onSetDefault {
                    Button("Set DEFAULT", action: onSetDefault)
                }
            }
        } label: {
            Text(displayLabel)
                .font(themeEngine.valueFontSwiftUI)
                .foregroundStyle(context.valueState.placeholder == nil ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 5))
        .popover(isPresented: $isEditorPresented) {
            ArrayValueEditorView(
                literal: initialLiteral,
                allowedValues: allowedValues,
                isNullable: false,
                delimiter: PostgresArrayDelimiter.forColumn(context.columnType),
                elementEditor: elementEditor,
                isReadOnly: context.isReadOnly,
                onCommit: { context.value.wrappedValue = $0 ?? "" },
                onDismiss: { isEditorPresented = false }
            )
        }
    }

    /// Follows `valueState`, so a NULL column says NULL, a multi-row selection that disagrees says
    /// so, and a literal the user has just committed shows what they built.
    private var displayLabel: String {
        if let placeholder = context.valueState.placeholder { return placeholder }
        let text = context.valueState.editableText
        return text.isEmpty ? String(localized: "Empty array") : text
    }

    /// The field resolves to this editor only for a literal the list can read, but the resolved
    /// kind is cached on the field, so an **Edit as Text** commit of a bounds-prefixed or
    /// multi-dimensional literal reaches the popover again. The editor takes the literal and opens
    /// its raw text mode over it, rather than showing an empty list that the next OK would write
    /// over the user's value.
    private var initialLiteral: String {
        let text = context.valueState.editableText
        return text.isEmpty
            ? PostgresArrayLiteralCodec.serialize(
                [],
                delimiter: PostgresArrayDelimiter.forColumn(context.columnType)
            )
            : text
    }
}
