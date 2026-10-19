import AppKit
import SwiftUI
import TableProGrammars
import TableProTheme

/// A fenced code block in a chat reply: selectable text in the editor's font and colors, as tall as its code.
///
/// It holds no scroll view of its own. The HIG asks not to nest a scroll view inside another of the same
/// orientation, and an inner one that cannot show all its code takes the transcript's scroll whenever the pointer
/// crosses it.
struct AIChatCodeBlockView: View, Equatable {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    let code: String
    let language: String?
    /// False while the block is the end of a reply still arriving. It shows plain editor text until then, so a
    /// half-written block is not reparsed and recolored on every flush.
    var isSettled: Bool = true

    static func == (lhs: AIChatCodeBlockView, rhs: AIChatCodeBlockView) -> Bool {
        lhs.code == rhs.code
            && lhs.language == rhs.language
            && lhs.isSettled == rhs.isSettled
    }

    @State private var isCopied: Bool = false
    @State private var highlighted: (key: String, text: AttributedString)?
    @Environment(\.commandActions) private var actions

    var body: some View {
        let resolvedLanguage = Self.resolvedLanguage(hint: language, code: code)
        let codeLanguage = Self.codeLanguage(for: resolvedLanguage)
        GroupBox {
            codeText(language: codeLanguage)
        } label: {
            header(resolvedLanguage: resolvedLanguage, isInsertable: codeLanguage.id != CodeLanguage.default.id)
        }
        .groupBoxStyle(CodeBlockGroupBoxStyle())
    }

    private func header(resolvedLanguage: String?, isInsertable: Bool) -> some View {
        HStack(spacing: 8) {
            if let resolvedLanguage {
                Text(resolvedLanguage.uppercased())
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .separatorColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Spacer(minLength: 0)

            Button {
                ClipboardService.shared.writeText(code)
                isCopied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    isCopied = false
                }
            } label: {
                Label(
                    isCopied ? String(localized: "Copied") : String(localized: "Copy"),
                    systemImage: isCopied ? "checkmark" : "doc.on.doc"
                )
                .font(.caption2)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .fixedSize()

            if isInsertable {
                Button {
                    actions?.insertQueryFromAI(code)
                } label: {
                    Label(String(localized: "Insert"), systemImage: "square.and.pencil")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .fixedSize()
                .disabled(actions == nil)
                .help(actions == nil
                    ? String(localized: "Open a connection to insert")
                    : String(localized: "Insert into editor"))
            }
        }
    }

    private func codeText(language: CodeLanguage) -> some View {
        let font = themeEngine.editorFonts.font
        let key = isSettled
            ? CodeBlockHighlighter.key(for: code, language: language, font: font, themeEngine: themeEngine)
            : nil
        let marked = key.flatMap { key in
            highlighted?.key == key ? highlighted?.text : CodeBlockHighlighter.cachedCode(forKey: key)
        }
        return Text(code.isEmpty ? AttributedString(" ") : marked ?? AttributedString(code))
            .font(Font(font))
            .themeForeground(.editorText, native: Color(nsColor: .textColor))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .themeBackground(.editorBackground, native: Color(nsColor: .textBackgroundColor))
            .task(id: key) {
                guard let key, marked == nil else { return }
                let text = await CodeBlockHighlighter.highlightedCode(
                    code,
                    language: language,
                    font: font,
                    key: key,
                    themeEngine: themeEngine
                )
                highlighted = (key, text)
            }
    }

    private static func resolvedLanguage(hint: String?, code: String) -> String? {
        if let hint, !hint.isEmpty {
            return hint
        }
        return detectLanguage(from: code)
    }

    /// Reads only up to the first line that is not blank or a comment, so a long block costs no more than a short one.
    nonisolated static func detectLanguage(from code: String) -> String? {
        var firstStatement: String?
        code.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("--"), !trimmed.hasPrefix("/*") else { return }
            firstStatement = trimmed.uppercased()
            stop = true
        }
        guard let firstStatement else { return nil }

        let sqlPrefixes = [
            "SELECT ", "INSERT ", "UPDATE ", "DELETE ", "WITH ",
            "EXPLAIN ", "PRAGMA ", "CREATE ", "ALTER ", "DROP ",
            "TRUNCATE ", "BEGIN ", "COMMIT ", "ROLLBACK ", "GRANT ",
            "REVOKE ", "ANALYZE ", "SET ", "CALL ", "LOCK ",
            "MERGE ", "SHOW ", "DESCRIBE ", "DESC "
        ]
        if sqlPrefixes.contains(where: { firstStatement.hasPrefix($0) }) {
            return "sql"
        }
        if firstStatement.hasPrefix("DB.") {
            return "javascript"
        }
        return nil
    }

    private static func codeLanguage(for resolvedLanguage: String?) -> CodeLanguage {
        switch resolvedLanguage?.lowercased() {
        case "sql", "mysql", "postgresql", "postgres", "sqlite":
            return .sql
        case "javascript", "js", "mongodb", "mongo":
            return .javascript
        case "redis", "bash", "shell", "sh":
            return .bash
        default:
            return .default
        }
    }
}

private struct CodeBlockGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
