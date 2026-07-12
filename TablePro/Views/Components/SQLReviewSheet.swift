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
    struct PrimaryAction {
        let title: String
        let isDestructive: Bool
        let perform: () async -> Void

        init(title: String, isDestructive: Bool, perform: @escaping () async -> Void) {
            self.title = title
            self.isDestructive = isDestructive
            self.perform = perform
        }
    }

    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    let statements: [String]
    let databaseType: DatabaseType

    var warning: String?
    var failure: String?
    var primaryAction: PrimaryAction?
    var onOpenInEditor: (() -> Void)?

    @State private var prepared: Prepared?
    @State private var copied = false
    @State private var editorState: SourceEditorState?
    @State private var isExecuting = false

    enum DisplayMode {
        case rich
        case plain
        case truncated
    }

    struct Prepared: Equatable {
        let display: String
        let full: String
        let mode: DisplayMode
    }

    /// Past this many characters the display is truncated; the full text stays available via Copy All.
    nonisolated static let maxDisplayChars = 20_000
    /// Past this many characters tree-sitter is skipped in favour of a plain monospaced view.
    nonisolated static let treeSitterCutoff = 8_000

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            content

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 560, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { dismiss() }
        .task { await prepare() }
    }

    @ViewBuilder
    private var content: some View {
        if statements.isEmpty {
            emptyState
        } else if let prepared {
            editor(for: prepared)
                .padding(16)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func prepare() async {
        guard prepared == nil, !statements.isEmpty else { return }
        let isJavaScript = PluginManager.shared.editorLanguage(for: databaseType) == .javascript
        let result = await Task.detached(priority: .userInitiated) { [statements, isJavaScript] in
            Self.build(statements: statements, isJavaScript: isJavaScript)
        }.value
        prepared = result
    }

    static func build(statements: [String], databaseType: DatabaseType) -> Prepared {
        let isJavaScript = PluginManager.shared.editorLanguage(for: databaseType) == .javascript
        return build(statements: statements, isJavaScript: isJavaScript)
    }

    nonisolated private static func build(statements: [String], isJavaScript: Bool) -> Prepared {
        var full = statements
            .map { $0.hasSuffix(";") ? $0 : $0 + ";" }
            .joined(separator: "\n\n")
        if isJavaScript {
            full = convertExtendedJsonToShellSyntax(full)
        }

        let nsFull = full as NSString
        let fullCount = nsFull.length
        if fullCount > maxDisplayChars {
            let head = nsFull.substring(to: maxDisplayChars)
            let remaining = fullCount - maxDisplayChars
            let note = String(
                format: String(localized: "-- … %d more characters not shown; use Copy All for the full output."),
                remaining
            )
            return Prepared(
                display: head + "\n\n" + note,
                full: full,
                mode: .truncated
            )
        }

        return Prepared(
            display: full,
            full: full,
            mode: fullCount <= treeSitterCutoff ? .rich : .plain
        )
    }

    nonisolated static func convertExtendedJsonToShellSyntax(_ mql: String) -> String {
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
                .disabled(prepared == nil)
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
    private func editor(for prepared: Prepared) -> some View {
        switch prepared.mode {
        case .rich:
            richEditor(prepared.display)
        case .plain, .truncated:
            plainTextEditor(prepared.display)
        }
    }

    private func richEditor(_ text: String) -> some View {
        let stateBinding = Binding<SourceEditorState>(
            get: { editorState ?? SourceEditorState() },
            set: { editorState = $0 }
        )
        return SourceEditor(
            .constant(text),
            language: PluginManager.shared.editorLanguage(for: databaseType).treeSitterLanguage,
            configuration: Self.makeConfiguration(),
            state: stateBinding
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func plainTextEditor(_ text: String) -> some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 8) {
            if let failure {
                InlineErrorBanner(message: failure)
            }
            HStack(spacing: 12) {
                if let onOpenInEditor {
                    Button(String(localized: "Open in Query Editor"), action: onOpenInEditor)
                        .controlSize(.small)
                        .disabled(statements.isEmpty || isExecuting)
                }
                if prepared?.mode == .truncated {
                    Label(
                        String(localized: "Output truncated for display"),
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if isExecuting {
                    ProgressView().controlSize(.small)
                }
                if let primaryAction {
                    Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isExecuting)
                    executeButton(primaryAction)
                } else {
                    Button(String(localized: "Done")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    @ViewBuilder
    private func executeButton(_ action: PrimaryAction) -> some View {
        let button = Button(action.title, role: action.isDestructive ? .destructive : nil) {
            isExecuting = true
            Task {
                await action.perform()
                isExecuting = false
            }
        }
        .disabled(statements.isEmpty || isExecuting)
        .accessibilityIdentifier("sql-review-execute")

        if action.isDestructive {
            button
        } else {
            button.keyboardShortcut(.defaultAction)
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
        guard let prepared else { return }
        ClipboardService.shared.writeText(prepared.full)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
