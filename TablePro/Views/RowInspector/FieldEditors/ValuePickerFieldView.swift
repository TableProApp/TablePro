//
//  ValuePickerFieldView.swift
//  TablePro
//

import SwiftUI

/// A field with suggestions the user may ignore: the same menu the structure grid opens from its
/// cell chevron, over the same free-form text field every other schema field uses.
///
/// `EnumPickerView` cannot serve here. Its list is the whole set of legal values, so it has no way to
/// hold a value that is not in it, and a column default is an open-ended SQL expression.
internal struct ValuePickerFieldView: View {
    internal let context: FieldEditorContext
    internal let options: [GridMenuOption]

    @State private var isCustomPresented = false

    var body: some View {
        HStack(spacing: 4) {
            SchemaTextFieldView(context: context)

            Menu {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    menuEntry(option)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(context.isReadOnly)
            .accessibilityLabel(String(localized: "Choose Value"))
            /// A SwiftUI `Menu` is an `NSPopUpButton` on macOS, so it publishes `menuButton` or
            /// `popUpButton` and never `button`, and no suite has ever resolved one by its label.
            /// The identifier is the hook `InspectorFieldRow`'s own value menu already carries, and
            /// unlike the label it does not move with the display language.
            .accessibilityIdentifier("column-default-menu")
            .popover(isPresented: $isCustomPresented) {
                CustomValueContentView(
                    initialValue: context.value.wrappedValue,
                    escapeStringLiteral: escapeStringLiteral,
                    stringLiteralPrefix: stringLiteralPrefix,
                    onCommit: { context.value.wrappedValue = $0 },
                    onDismiss: { isCustomPresented = false }
                )
            }
        }
    }

    @ViewBuilder
    private func menuEntry(_ option: GridMenuOption) -> some View {
        switch option {
        case .sectionHeader(let title):
            Divider()
            Text(title)
        case .value(let title, let sql):
            Button {
                context.value.wrappedValue = sql
            } label: {
                if sql == context.value.wrappedValue {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        case .clear(let title):
            Button(title) { context.value.wrappedValue = "" }
        case .custom(let title):
            Divider()
            Button(title) { isCustomPresented = true }
        }
    }

    /// The connected driver's own escaping, the same seam the grid's chevron menu uses, so the two
    /// surfaces cannot escape one value two ways. It falls back to the shared helper only where the
    /// field has no connection behind it, which is every field outside a structure row.
    private var escapeStringLiteral: (String) -> String {
        guard let connectionId = context.userDefinedTypeScope?.connectionId,
              let driver = DatabaseManager.shared.driver(for: connectionId) else {
            return SQLEscaping.escapeStringLiteral
        }
        return driver.escapeStringLiteral
    }

    /// From the same connection the escaping comes from, so a default typed here is written the
    /// way the engine reads it back. No connection means no prefix, which is what every engine but
    /// SQL Server wants anyway.
    private var stringLiteralPrefix: String {
        guard let connectionId = context.userDefinedTypeScope?.connectionId,
              let driver = DatabaseManager.shared.driver(for: connectionId) else {
            return ""
        }
        return SQLStringLiteralPrefix.forDatabaseType(driver.connection.type)
    }
}
