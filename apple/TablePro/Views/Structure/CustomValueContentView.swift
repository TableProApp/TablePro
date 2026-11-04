//
//  CustomValueContentView.swift
//  TablePro
//
//  Enters a cell value the menu cannot spell, as either text or a SQL expression.
//

import SwiftUI
import TableProSQLQuoting

/// The editor behind a chevron menu's `Custom…` item.
///
/// The two modes exist because the field holds SQL, and text and SQL are not the same value:
/// `pending` is a column reference, `'pending'` is a string. Guessing which one was meant is what
/// made a default of `gen_random_uuid()` arrive at the server as the eleven-character string.
internal struct CustomValueContentView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    internal enum Mode: Hashable {
        case text
        case expression
    }

    internal let initialValue: String
    /// The connected driver's own escaping, so a value is escaped the way the engine reads it.
    /// MySQL doubles backslashes as well as quotes, which the shared helper does not.
    internal let escapeStringLiteral: (String) -> String
    /// What the engine puts in front of a string literal, `N` on SQL Server and nothing anywhere
    /// else. A default written without it is a `varchar` literal, so a non-Unicode collation turns
    /// every character outside its code page into `?` as it parses the `ALTER TABLE`.
    internal let stringLiteralPrefix: String
    internal let onCommit: (String) -> Void
    internal let onDismiss: () -> Void

    @State private var mode: Mode
    @State private var text: String
    @FocusState private var isFieldFocused: Bool

    internal init(
        initialValue: String,
        escapeStringLiteral: @escaping (String) -> String,
        stringLiteralPrefix: String = "",
        onCommit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.initialValue = initialValue
        self.escapeStringLiteral = escapeStringLiteral
        self.stringLiteralPrefix = stringLiteralPrefix
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        let initial = Self.initialMode(
            of: initialValue, escapeStringLiteral: escapeStringLiteral, stringLiteralPrefix: stringLiteralPrefix
        )
        _mode = State(initialValue: initial.mode)
        _text = State(initialValue: initial.text)
    }

    // Doubled quotes undone and nothing else; a value that does not re-encode to itself, a MySQL backslash escape for
    // one, is edited as the expression it already is rather than escaped again on every save.
    static func initialMode(
        of value: String,
        escapeStringLiteral: (String) -> String,
        stringLiteralPrefix: String
    ) -> (mode: Mode, text: String) {
        let quotedPart = stringLiteralPrefix.isEmpty || !value.hasPrefix(stringLiteralPrefix)
            ? value
            : String(value.dropFirst(stringLiteralPrefix.count))
        guard let text = SQLQuoting.decodedStringLiteral(quotedPart),
              value.unicodeScalars.elementsEqual("\(stringLiteralPrefix)'\(escapeStringLiteral(text))'".unicodeScalars)
        else { return (.expression, value) }
        return (.text, text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(String(localized: "Value"), selection: $mode) {
                Text("Text").tag(Mode.text)
                Text("SQL expression").tag(Mode.expression)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(mode == .expression ? themeEngine.valueFontSwiftUI : nil)
                .focused($isFieldFocused)
                .onSubmit(commit)

            Text(preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Set"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty && mode == .expression)
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { isFieldFocused = true }
    }

    private var placeholder: String {
        switch mode {
        case .text: String(localized: "Text value")
        case .expression: String(localized: "SQL expression")
        }
    }

    private var preview: String {
        String(format: String(localized: "Sets the value to %@"), resolvedSQL)
    }

    private var resolvedSQL: String {
        switch mode {
        case .text: "\(stringLiteralPrefix)'\(escapeStringLiteral(text))'"
        case .expression: text
        }
    }

    private func commit() {
        let sql = resolvedSQL
        guard !sql.isEmpty else { return }
        onCommit(sql)
        onDismiss()
    }
}
