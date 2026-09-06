//
//  FieldEditorContent.swift
//  TablePro
//

import SwiftUI

/// Builds the editor a field's kind asks for.
///
/// The switch is exhaustive on purpose: it is the one place that has to know every kind, and
/// anything else that switches over `FieldEditorKind` has to agree with it. It used to have two
/// `default`-armed siblings deciding the font and the height, which disagreed with it and shipped
/// two fonts in one pane.
internal struct FieldEditorContent: View {
    internal let context: FieldEditorContext
    internal let kind: FieldEditorKind
    internal let databaseType: DatabaseType
    internal var onSetNull: (() -> Void)?
    internal var onSetDefault: (() -> Void)?
    internal var onPopOut: ((String) -> Void)?
    internal var isExpanded = false

    var body: some View {
        if context.valueState.isPending, !isPicker {
            PendingStatePill(state: context.valueState, minHeight: Self.pillHeight(for: kind))
        } else {
            editor
        }
    }

    /// A picker shows its pending state as its own selection, so replacing it with a pill would
    /// take away the control that changes it back.
    private var isPicker: Bool {
        switch kind {
        case .boolean, .enumPicker, .setPicker, .typePicker: return true
        case .json, .phpSerialized, .image, .blobHex, .schemaText, .multiLine, .singleLine: return false
        }
    }

    /// Only the pill takes a height from here. Every editor owns its own, and forcing one on the
    /// resizable ones from outside would stop the drag handle shrinking them past this floor.
    private static func pillHeight(for kind: FieldEditorKind) -> CGFloat? {
        switch kind {
        case .json, .phpSerialized: return 80
        case .image: return 200
        case .blobHex: return 60
        case .multiLine: return ResizableFieldMetrics.defaultTextHeight
        case .boolean, .enumPicker, .setPicker, .typePicker, .schemaText, .singleLine: return nil
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch kind {
        case .json:
            JsonEditorView(context: context, onPopOut: onPopOut, isExpanded: isExpanded)
        case .phpSerialized:
            PhpSerializedFieldView(context: context, onPopOut: onPopOut, isExpanded: isExpanded)
        case .image(let format):
            ImageFieldView(context: context, format: format)
        case .blobHex:
            BlobHexEditorView(context: context)
        case .boolean:
            BooleanPickerView(context: context, onSetNull: onSetNull, onSetDefault: onSetDefault)
        case .enumPicker(let values):
            EnumPickerView(context: context, values: values, onSetNull: onSetNull, onSetDefault: onSetDefault)
        case .setPicker(let values):
            SetPickerView(context: context, values: values, onSetNull: onSetNull, onSetDefault: onSetDefault)
        case .typePicker:
            TypePickerFieldView(context: context, databaseType: databaseType)
        case .schemaText:
            SchemaTextFieldView(context: context)
        case .multiLine:
            MultiLineEditorView(context: context, onPopOut: onPopOut, isExpanded: isExpanded)
        case .singleLine:
            SingleLineEditorView(context: context)
        }
    }
}

/// What a field shows in place of its editor once the user has asked for NULL or DEFAULT.
internal struct PendingStatePill: View {
    internal let state: FieldValueState
    internal var minHeight: CGFloat?

    var body: some View {
        Text(state.placeholder ?? "")
            .font(ThemeEngine.shared.valueFontSwiftUI)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
