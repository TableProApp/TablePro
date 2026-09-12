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
        /// Answering a confirmation is instant and must not wait on a task being scheduled. The
        /// windowless path holds the main actor inside `NSApp.runModal` until this button resolves
        /// its gate, and the loop only unwinds once it does, so work deferred to a `Task` would be
        /// waiting on the loop that is waiting on it. Applying a plan is the other shape: it takes
        /// as long as the server does and wants the progress the task form gives it.
        enum Work {
            case immediate(@MainActor () -> Void)
            case asynchronous(@MainActor () async -> Void)
        }

        let title: String
        let isDestructive: Bool
        /// Return belongs to the confirming button only when the user asked for this dialog. A
        /// confirmation something else raised steals focus to do it, so a Return already on its way
        /// to the user's editor would answer it. `AlertHelper.addConfirmAndCancel` takes Return off
        /// the confirming button for the same reason.
        let takesDefaultAction: Bool
        let work: Work

        init(
            title: String,
            isDestructive: Bool,
            takesDefaultAction: Bool = true,
            perform: @escaping @MainActor () async -> Void
        ) {
            self.init(
                title: title,
                isDestructive: isDestructive,
                takesDefaultAction: takesDefaultAction,
                work: .asynchronous(perform)
            )
        }

        init(
            title: String,
            isDestructive: Bool,
            takesDefaultAction: Bool = true,
            work: Work
        ) {
            self.title = title
            self.isDestructive = isDestructive
            self.takesDefaultAction = takesDefaultAction
            self.work = work
        }
    }

    /// The one way out. `@Environment(\.dismiss)` cannot serve alongside it, because it is inert
    /// once the sheet is hosted in an `NSWindow` rather than presented by SwiftUI, which is how a
    /// statement confirmation reaches a Mac with no window open.
    @Binding var isPresented: Bool

    let statements: [String]
    let databaseType: DatabaseType

    /// Replaces the default "<Language> Preview" heading. A confirmation names the operation.
    var title: String?
    /// The sentence under the heading: who is asking, and which connection.
    var subtitle: String?
    /// Show the statements exactly as they will be sent. A preview may make MQL easier to read by
    /// rewriting `{"$oid": "…"}` as `ObjectId("…")` and by ending each statement with a semicolon;
    /// a confirmation may not, because the user is agreeing to the text in front of them.
    var showsStatementsVerbatim = false
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
        .onExitCommand { isPresented = false }
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
        let isJavaScript = !showsStatementsVerbatim
            && PluginManager.shared.editorLanguage(for: databaseType) == .javascript
        let verbatim = showsStatementsVerbatim
        let result = await Task.detached(priority: .userInitiated) { [statements, isJavaScript, verbatim] in
            Self.build(statements: statements, isJavaScript: isJavaScript, verbatim: verbatim)
        }.value
        prepared = result
    }

    static func build(statements: [String], databaseType: DatabaseType, verbatim: Bool = false) -> Prepared {
        let isJavaScript = !verbatim && PluginManager.shared.editorLanguage(for: databaseType) == .javascript
        return build(statements: statements, isJavaScript: isJavaScript, verbatim: verbatim)
    }

    nonisolated private static func build(statements: [String], isJavaScript: Bool, verbatim: Bool) -> Prepared {
        var full = verbatim
            ? statements.joined(separator: "\n\n")
            : statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
        if isJavaScript {
            full = convertExtendedJsonToShellSyntax(full)
        }

        let nsFull = full as NSString
        let fullCount = nsFull.length
        /// A preview may stop early and leave the rest to Copy All. A confirmation may not: the
        /// statement's `WHERE` clause can sit past any cut, and approving what you cannot see is
        /// the whole of what this dialog exists to prevent. `execute_query` accepts 102,400 units,
        /// which the text view below renders and a SwiftUI `Text` does not.
        if verbatim {
            return Prepared(
                display: full,
                full: full,
                mode: fullCount <= treeSitterCutoff ? .rich : .plain
            )
        }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title ?? defaultTitle)
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
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var defaultTitle: String {
        String(
            format: String(localized: "%@ Preview"),
            PluginManager.shared.queryLanguageName(for: databaseType)
        )
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
            state: stateBinding,
            foldProvider: FoldProviderResolver.provider(for: databaseType)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    /// A text view rather than a `Text` in a `ScrollView`: this path carries everything past the
    /// tree-sitter cutoff, which for a confirmation is the whole statement however long it is, and
    /// a single `Text` that size lays out for seconds. It wears the editor's own background, text
    /// colour and syntax palette, which is what a hand-themed `Text` here was reaching for.
    private func plainTextEditor(_ text: String) -> some View {
        HighlightedSQLTextView(sql: text, databaseType: databaseType)
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
                    Button(String(localized: "Cancel"), role: .cancel) { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isExecuting)
                    executeButton(primaryAction)
                } else {
                    Button(String(localized: "Done")) { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    @ViewBuilder
    private func executeButton(_ action: PrimaryAction) -> some View {
        let button = Button(action.title, role: action.isDestructive ? .destructive : nil) {
            switch action.work {
            case .immediate(let perform):
                perform()
            case .asynchronous(let perform):
                isExecuting = true
                Task {
                    await perform()
                    isExecuting = false
                }
            }
        }
        .disabled(statements.isEmpty || isExecuting || prepared == nil)
        .accessibilityIdentifier("sql-review-execute")

        if action.isDestructive || !action.takesDefaultAction {
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
            peripherals: EditorPeripherals.preview(
                folding: AppSettingsManager.shared.editor.codeFoldingEnabled
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
