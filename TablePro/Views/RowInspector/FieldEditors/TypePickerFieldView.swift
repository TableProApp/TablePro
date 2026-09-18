//
//  TypePickerFieldView.swift
//  TablePro
//

import SwiftUI

/// Column type editor for a schema field: free-form text for lengths and precision,
/// plus the same searchable type list the structure grid opens from its cell chevron.
internal struct TypePickerFieldView: View {
    let context: FieldEditorContext
    let databaseType: DatabaseType

    @State private var isPickerPresented = false

    var body: some View {
        HStack(spacing: 4) {
            SchemaTextFieldView(context: context)

            Button {
                isPickerPresented = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(context.isReadOnly)
            .accessibilityLabel(String(localized: "Choose Type"))
            .popover(isPresented: $isPickerPresented) {
                UserDefinedTypeAwarePicker(scope: context.userDefinedTypeScope) { userDefinedTypes in
                    TypePickerContentView(
                        databaseType: databaseType,
                        currentValue: context.value.wrappedValue,
                        userDefinedTypes: userDefinedTypes,
                        onCommit: { context.value.wrappedValue = $0 },
                        onDismiss: { isPickerPresented = false }
                    )
                }
            }
        }
    }
}
