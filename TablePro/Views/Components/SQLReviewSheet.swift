//
//  SQLReviewSheet.swift
//  TablePro
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI
import TableProPluginKit

struct SQLReviewSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    let statements: [String]
    let databaseType: DatabaseType

    @State private var displaySQL = ""
    @State private var isReady = false
    @State private var copied = false
    @State private var editorState = SourceEditorState()

    private static let displayStatementCap = 100

    private var truncated: Bool {
        statements.count > Self.displayStatementCap
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            if statements.isEmpty {
                emptyState
            } else {
                editor
                    .padding(16)
            }

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 560, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: statementsFingerprint) {
            // Build the display string off the main render pass so a 1000-statement batch
            // doesn't burn CPU recomputing on every body call.
            let result = await Task.detached(priority: .userInitiated) { [statements, databaseType] in
                Self.buildDisplaySQL(statements: statements, databaseType: databaseType)
            }.value
            displaySQL = result
            isReady = true
        }
    }

    /// Cheap identity for .task(id:) (count + first/last hash) so the heavy join doesn't repeat
    /// when SwiftUI rebuilds the sheet body for the same statements.
    private var statementsFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(statements.count)
        if let first = statements.first { hasher.combine(first) }
        if let last = statements.last { hasher.combine(last) }
        return hasher.finalize()
    }

    private static func buildDisplaySQL(statements: [String], databaseType: DatabaseType) -> String {
        let limit = displayStatementCap
        let isJS = PluginManager.shared.editorLanguage(for: databaseType) == .javascript

        let visible = Array(statements.prefix(limit))
        var joined = visible.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")

        if statements.count > limit {
            let hidden = statements.count - limit
            let note = String(format: String(localized: "-- … %d more statements not shown; use Copy All for the full output."), hidden)
            joined += "\n\n" + note
        }

        if isJS {
            return convertExtendedJsonToShellSyntax(joined)
        }
        return joined
    }

    private static func convertExtendedJsonToShellSyntax(_ mql: String) -> String {
        let pattern = #"\{"\$oid":\s*"([0-9a-fA-F]{24})"\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return mql }
        let nsString = mql as NSString
        return regex.stringByReplacingMatches(
            in: mql,
            range: NSRange(location: 0, length: nsString.length),
            withTemplate: #"ObjectId("$1")"#
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(PluginManager.shared.queryLanguageName(for: databaseType)) Preview")
                .font(.body.weight(.semibold))
            if !statements.isEmpty {
                Text(
                    "(\(statements.count) \(statements.count == 1 ? String(localized: "statement") : String(localized: "statements")))"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !statements.isEmpty {
                Button(action: copyAll) {
                    Label(
                        copied ? String(localized: "Copied") : String(localized: "Copy All"),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.plaintext")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(String(localized: "No pending changes"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var editor: some View {
        if isReady {
            SourceEditor(
                .constant(displaySQL),
                language: PluginManager.shared.editorLanguage(for: databaseType).treeSitterLanguage,
                configuration: Self.makeConfiguration(),
                state: $editorState
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        } else {
            Color(nsColor: .textBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if truncated {
                Label(
                    String(
                        format: String(localized: "Showing first %d of %d statements"),
                        Self.displayStatementCap,
                        statements.count
                    ),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Done")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private static func makeConfiguration() -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                wrapLines: true
            ),
            behavior: .init(isEditable: false),
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

    private func copyAll() {
        let snapshot = statements
        let type = databaseType
        Task.detached(priority: .userInitiated) {
            let isJS = PluginManager.shared.editorLanguage(for: type) == .javascript
            var joined = snapshot
                .map { $0.hasSuffix(";") ? $0 : $0 + ";" }
                .joined(separator: "\n\n")
            if isJS {
                joined = Self.convertExtendedJsonToShellSyntax(joined)
            }
            await MainActor.run {
                ClipboardService.shared.writeText(joined)
                copied = true
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
