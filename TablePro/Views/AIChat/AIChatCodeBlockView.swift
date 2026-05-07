//
//  AIChatCodeBlockView.swift
//  TablePro
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

struct AIChatCodeBlockView: View {
    let code: String
    let language: String?

    @State private var isCopied: Bool = false
    @State private var isEditorReady = false
    @State private var editorState = SourceEditorState()
    @FocusedValue(\.commandActions) private var focusedActions
    @Bindable private var commandRegistry = CommandActionsRegistry.shared

    private var actions: MainContentCommandActions? {
        focusedActions ?? commandRegistry.current
    }

    var body: some View {
        GroupBox {
            codeContent
        } label: {
            codeBlockHeader
        }
        .groupBoxStyle(CodeBlockGroupBoxStyle())
        .task {
            isEditorReady = true
        }
        .onDisappear {
            isEditorReady = false
        }
    }

    private var codeBlockHeader: some View {
        HStack {
            if let resolved = resolvedLanguage {
                Text(resolved.uppercased())
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .separatorColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

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
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if isInsertable {
                Button {
                    actions?.insertQueryFromAI(code)
                } label: {
                    Label(String(localized: "Insert"), systemImage: "square.and.pencil")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(actions == nil)
                .help(actions == nil
                    ? String(localized: "Open a connection to insert")
                    : String(localized: "Insert into editor"))
            }
        }
    }

    @ViewBuilder
    private var codeContent: some View {
        if isEditorReady {
            SourceEditor(
                .constant(code),
                language: treeSitterLanguage,
                configuration: Self.makeConfiguration(),
                state: $editorState
            )
            .frame(height: editorHeight)
        } else {
            Color(nsColor: .textBackgroundColor)
                .frame(height: editorHeight)
        }
    }

    private var resolvedLanguage: String? {
        if let language, !language.isEmpty {
            return language
        }
        return Self.detectLanguage(from: code)
    }

    static func detectLanguage(from code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }
        let firstNonCommentLine = trimmed
            .split(whereSeparator: { $0.isNewline })
            .first(where: { line in
                let head = line.trimmingCharacters(in: .whitespaces)
                return !head.isEmpty && !head.hasPrefix("--") && !head.hasPrefix("/*")
            })
            .map(String.init) ?? trimmed

        let sqlPrefixes = [
            "SELECT ", "INSERT ", "UPDATE ", "DELETE ", "WITH ",
            "EXPLAIN ", "PRAGMA ", "CREATE ", "ALTER ", "DROP ",
            "TRUNCATE ", "BEGIN ", "COMMIT ", "ROLLBACK ", "GRANT ",
            "REVOKE ", "ANALYZE ", "SET ", "CALL ", "LOCK ",
            "MERGE ", "SHOW ", "DESCRIBE ", "DESC "
        ]
        if sqlPrefixes.contains(where: { firstNonCommentLine.hasPrefix($0) }) {
            return "sql"
        }
        if firstNonCommentLine.hasPrefix("DB.") {
            return "javascript"
        }
        return nil
    }

    private var treeSitterLanguage: CodeLanguage {
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

    private var isInsertable: Bool {
        treeSitterLanguage.id != .default
    }

    private var editorHeight: CGFloat {
        let lineHeight: CGFloat = 18
        let editorInsets: CGFloat = 16
        let lineCount = code.reduce(into: 1) { count, char in
            if char == "\n" { count += 1 }
        }
        let height = CGFloat(lineCount) * lineHeight + editorInsets
        return min(max(height, 32), 400)
    }

    private static func makeConfiguration() -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                wrapLines: true
            ),
            behavior: .init(
                isEditable: false
            ),
            layout: .init(
                contentInsets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            ),
            peripherals: .init(
                showGutter: false,
                showMinimap: false,
                showFoldingRibbon: false
            )
        )
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
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
