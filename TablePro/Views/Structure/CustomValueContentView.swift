//
//  CustomValueContentView.swift
//  TablePro
//
//  Enters a cell value the menu cannot spell, as either text or a SQL expression.
//

import SwiftUI

/// The editor behind a chevron menu's `Custom…` item.
///
/// The two modes exist because the field holds SQL, and text and SQL are not the same value:
/// `pending` is a column reference, `'pending'` is a string. Guessing which one was meant is what
/// made a default of `gen_random_uuid()` arrive at the server as the eleven-character string.
internal struct CustomValueContentView: View {
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
        let quotedPart = stringLiteralPrefix.isEmpty || !initialValue.hasPrefix(stringLiteralPrefix)
            ? initialValue
            : String(initialValue.dropFirst(stringLiteralPrefix.count))
        if let text = SQLStringLiteral.unquoted(quotedPart),
           initialValue == "\(stringLiteralPrefix)'\(escapeStringLiteral(text))'" {
            _mode = State(initialValue: .text)
            _text = State(initialValue: text)
        } else {
            _mode = State(initialValue: .expression)
            _text = State(initialValue: initialValue)
        }
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
                .font(mode == .expression ? ThemeEngine.shared.valueFontSwiftUI : nil)
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

/// Reading a SQL string literal back into the text it stands for.
///
/// It undoes doubled quotes and nothing else, which is the shared half of every dialect. The
/// engines that escape more than that (MySQL's backslashes, ClickHouse's control characters) are
/// why the caller checks that re-encoding the result reproduces the original before trusting it: a
/// value this cannot round-trip is edited as the expression it already is, rather than escaped a
/// second time on every open and save.
internal enum SQLStringLiteral {
    /// The text inside a single-quoted literal, or nil where the value is not one.
    ///
    /// A literal with an unescaped quote in the middle is not one value, so it reports nil rather
    /// than a truncated guess: `'a' || b` is an expression that happens to start with a quote.
    static func unquoted(_ value: String) -> String? {
        guard value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") else { return nil }
        let inner = String(value.dropFirst().dropLast())
        var result = ""
        var index = inner.startIndex
        while index < inner.endIndex {
            let character = inner[index]
            let next = inner.index(after: index)
            guard character == "'" else {
                result.append(character)
                index = next
                continue
            }
            guard next < inner.endIndex, inner[next] == "'" else { return nil }
            result.append("'")
            index = inner.index(after: next)
        }
        return result
    }
}
