//
//  SQLReviewPopover.swift
//  TablePro
//
//  Popover view for previewing SQL statements before committing changes.
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI
import TableProPluginKit

/// Popover view that displays SQL statements with tree-sitter syntax highlighting for review before commit.
struct SQLReviewPopover: View {
    let statements: [String]
    var databaseType: DatabaseType = .mysql

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var isEditorReady = false
    @State private var editorState = SourceEditorState()

    /// All statements joined for display
    private var combinedSQL: String {
        let joined = statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
        if PluginManager.shared.editorLanguage(for: databaseType) == .javascript {
            return Self.convertExtendedJsonToShellSyntax(joined)
        }
        return joined
    }

    /// Convert MongoDB Extended JSON to shell-friendly syntax for display.
    /// e.g. {"$oid": "abc123"} → ObjectId("abc123")
    private static func convertExtendedJsonToShellSyntax(_ mql: String) -> String {
        // Match {"$oid": "hexstring"} patterns
        let pattern = #"\{"\$oid":\s*"([0-9a-fA-F]{24})"\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return mql }
        let nsString = mql as NSString
        return regex.stringByReplacingMatches(
            in: mql,
            range: NSRange(location: 0, length: nsString.length),
            withTemplate: #"ObjectId("$1")"#
        )
    }

    /// Calculate popover height based on content lines
    private var contentHeight: CGFloat {
        let lineHeight: CGFloat = 18
        let headerHeight: CGFloat = 30
        let padding: CGFloat = ThemeEngine.shared.activeTheme.spacing.md * 2 + ThemeEngine.shared.activeTheme.spacing.sm
        let editorInsets: CGFloat = 16 // top + bottom content insets

        // Count lines directly from statements to avoid recomputing combinedSQL.
        // Each statement contributes its own line count, plus 2 separator lines (";\n\n")
        // between consecutive statements.
        let lineCount: Int = {
            guard !statements.isEmpty else { return 1 }
            let statementsLineCount = statements.reduce(0) { total, stmt in
                var newlines = 0
                for scalar in stmt.unicodeScalars where scalar == "\n" { newlines += 1 }
                return total + newlines + 1
            }
            // Add separator lines: each separator "\n\n" adds 2 newlines between statements
            let separatorLines = (statements.count - 1) * 2
            return statementsLineCount + separatorLines
        }()
        let editorHeight = CGFloat(lineCount) * lineHeight + editorInsets
        let totalHeight = headerHeight + editorHeight + padding

        return min(max(totalHeight, 120), 500)
    }

    var body: some View {
        VStack(spacing: ThemeEngine.shared.activeTheme.spacing.sm) {
            headerView
            if statements.isEmpty {
                emptyState
            } else {
                editorView
            }
        }
        .padding(ThemeEngine.shared.activeTheme.spacing.md)
        .frame(width: 520, height: contentHeight)
        .onExitCommand {
            dismiss()
        }
        .onAppear {
            // Defer SourceEditor creation to avoid toolbar layout crash
            DispatchQueue.main.async {
                isEditorReady = true
            }
        }
        .onDisappear {
            isEditorReady = false
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("\(PluginManager.shared.queryLanguageName(for: databaseType)) Preview")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .semibold))
            if !statements.isEmpty {
                Text(
                    "(\(statements.count) \(statements.count == 1 ? String(localized: "statement") : String(localized: "statements")))"
                )
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !statements.isEmpty {
                Button(action: copyAllToClipboard) {
                    HStack(spacing: ThemeEngine.shared.activeTheme.spacing.xxs) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? String(localized: "Copied!") : String(localized: "Copy All"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: ThemeEngine.shared.activeTheme.spacing.xs) {
            Spacer()
            Image(systemName: "doc.plaintext")
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.huge))
                .foregroundStyle(.tertiary)
            Text(String(localized: "No pending changes"))
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorView: some View {
        if isEditorReady {
            SourceEditor(
                .constant(combinedSQL),
                language: PluginManager.shared.editorLanguage(for: databaseType).treeSitterLanguage,
                configuration: Self.makeConfiguration(),
                state: $editorState
            )
            .clipShape(RoundedRectangle(cornerRadius: ThemeEngine.shared.activeTheme.cornerRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: ThemeEngine.shared.activeTheme.cornerRadius.medium)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        } else {
            // Lightweight placeholder while SourceEditor loads
            Color(nsColor: .textBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: ThemeEngine.shared.activeTheme.cornerRadius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: ThemeEngine.shared.activeTheme.cornerRadius.medium)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Configuration

    private static func makeConfiguration() -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: NSFont.monospacedSystemFont(
                    ofSize: ThemeEngine.shared.activeTheme.typography.medium, weight: .regular),
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

    // MARK: - Clipboard

    private func copyAllToClipboard() {
        var joined = statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
        if PluginManager.shared.editorLanguage(for: databaseType) == .javascript {
            joined = Self.convertExtendedJsonToShellSyntax(joined)
        }
        ClipboardService.shared.writeText(joined)
        copied = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
