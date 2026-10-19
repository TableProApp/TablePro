import SwiftUI
import TableProTheme

internal struct SingleLineEditorView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    let context: FieldEditorContext

    var body: some View {
        if context.isReadOnly {
            readOnlyValue
        } else {
            ValueTextField(text: context.value, placeholder: context.placeholderText, font: themeEngine.valueFont)
                .valueWell()
        }
    }

    /// A disabled text field takes no first responder, so a read-only value could be neither
    /// selected nor copied out of the field. Selectable text is the read-only presentation.
    private var readOnlyValue: some View {
        let value = context.value.wrappedValue
        let placeholder = value.isEmpty ? context.emptyStatePlaceholder : nil
        return Group {
            if let placeholder {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
            } else {
                Text(value)
                    .themeForeground(.editorText, native: .primary)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
        .valueWellPadding()
        .valueWell()
    }
}
