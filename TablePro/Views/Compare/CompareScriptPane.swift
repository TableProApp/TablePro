//
//  CompareScriptPane.swift
//  TablePro
//
//  The generated script, read-only, with the statements it is holding back.
//
//  The script is not editable. Each statement carries the hazards the operation
//  plan computed for it, and there is no way to recover those from edited text,
//  so an editable script would quietly drop the only thing standing between a
//  DROP COLUMN and the target.
//

import SwiftUI
import UniformTypeIdentifiers

internal struct CompareScriptPane: View {
    @Bindable internal var session: CompareSyncSession
    internal let onGenerateScript: () -> Void

    @AppStorage("structureCodeFontSize", store: AppStorageEnvironment.shared.defaults) private var fontSize = 13.0

    @State private var isExporting = false

    internal var body: some View {
        if session.statements.isEmpty {
            emptyState
        } else {
            scriptContent
        }
    }

    // MARK: - Script

    private var scriptContent: some View {
        let script = scriptText
        return VStack(spacing: 0) {
            header(script: script)
            Divider()
            if heldBackStatements.isEmpty {
                editor(script: script)
            } else {
                /// `VSplitView` gets no divider cursor once it is hosted inside SwiftUI: AppKit's
                /// cursor-rect system never fires there, so the divider drags while the pointer
                /// never changes. `AutosavingSplitView` sits on `ResizeCursorSplitViewController`,
                /// which is why every other divider in this window is one.
                AutosavingSplitView(
                    autosaveName: "com.TablePro.CompareSync.script",
                    isVertical: false,
                    primaryMinimum: 120,
                    secondaryMinimum: 160
                ) {
                    hazardList
                } secondary: {
                    editor(script: script)
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: SyncScriptDocument(text: script),
            contentType: SyncScriptDocument.sqlType,
            defaultFilename: exportFileName
        ) { _ in }
    }

    private func header(script: String) -> some View {
        HStack(spacing: 12) {
            Text(statementSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !heldBackStatements.isEmpty {
                Label {
                    Text(heldBackSummary)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                }
                .font(.callout)
                .foregroundStyle(CompareStatusStyle.warning)
            }
            Spacer(minLength: 0)
            Button("Copy") {
                ClipboardService.shared.writeText(script)
            }
            .accessibilityIdentifier("compare.script.copy")
            Button("Save\u{2026}") {
                isExporting = true
            }
            .accessibilityIdentifier("compare.script.save")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func editor(script: String) -> some View {
        DDLTextView(ddl: script, fontSize: $fontSize, databaseType: session.target?.databaseType)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hazards

    private var hazardList: some View {
        List {
            Section {
                ForEach(heldBackStatements) { statement in
                    CompareHeldBackStatementRow(statement: statement, session: session)
                }
            } header: {
                Text("Held Back")
            } footer: {
                Text("Allowing a statement applies to this run only. It is never saved.")
            }
        }
        .listStyle(.inset)
    }

    private var heldBackStatements: [SyncStatement] {
        session.statements.filter { $0.isRefusedByDefault }
    }

    // MARK: - Text

    private var scriptText: String {
        session.statements.map { $0.sql }.joined(separator: "\n")
    }

    /// `database` is the whole file path on SQLite and DuckDB, so Save… prefilled
    /// `/Users/…/Chinook.sqlite-sync`. `databaseLabel` is the shortened name the rest of the window
    /// already shows.
    private var exportFileName: String {
        guard let target = session.target, !target.databaseLabel.isEmpty else { return "sync" }
        return "\(target.databaseLabel)-sync"
    }

    /// One statement reads "1 statement". The count that carries the noun is the first argument and
    /// the second is bare, so the singular is chosen here rather than in the format string.
    private var statementSummary: String {
        let total = session.statements.count
        guard total != 1 else {
            return String(format: String(localized: "1 statement, %d will run."), session.runnableStatementCount)
        }
        return String(
            format: String(localized: "%1$d statements, %2$d will run."),
            total, session.runnableStatementCount
        )
    }

    private var heldBackSummary: String {
        String(
            format: String(localized: "%1$d of %2$d allowed for this run"),
            heldBackStatements.count - session.unacknowledgedHazardCount,
            heldBackStatements.count
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Script Yet", systemImage: "doc.plaintext")
        } description: {
            Text(emptyDescription)
        } actions: {
            Button("Generate Script", action: onGenerateScript)
                .disabled(!session.canBuildScript)
                .accessibilityIdentifier("compare.script.generate")
        }
    }

    /// The one reason Generate Script is unavailable, rather than this pane's own second guess at it.
    /// `scriptDisabledReason` already carries the cross-engine refusal, the missing comparison and
    /// the empty selection, and it is what the toolbar item's tooltip reads.
    private var emptyDescription: String {
        session.scriptDisabledReason
            ?? String(localized: "Generate the script to see exactly what would run.")
    }
}

internal struct CompareHeldBackStatementRow: View {
    internal let statement: SyncStatement
    @Bindable internal var session: CompareSyncSession

    internal var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: CompareHazardAllowance.binding(for: statement, in: session)) {
                Text(statement.summary)
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("compare.script.allow.\(statement.id.uuidString)")

            ForEach(statement.hazards) { hazard in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hazard.kind.displayName)
                            .font(.caption.weight(.semibold))
                        Text(hazard.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(CompareStatusStyle.warning)
                }
            }

            Text(statement.sql)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }
}

/// One writer for the allowance set, because the script pane and the Apply sheet both offer it. Two
/// copies of the same insert-or-remove is how the two surfaces drift apart, and this set is what
/// stands between a DROP COLUMN and the target.
internal enum CompareHazardAllowance {
    @MainActor
    internal static func binding(for statement: SyncStatement, in session: CompareSyncSession) -> Binding<Bool> {
        Binding(
            get: { session.executionSettings.allowedHazardStatementIds.contains(statement.id) },
            set: { allowed in
                if allowed {
                    session.executionSettings.allowedHazardStatementIds.insert(statement.id)
                } else {
                    session.executionSettings.allowedHazardStatementIds.remove(statement.id)
                }
            }
        )
    }
}

internal struct SyncScriptDocument: FileDocument {
    internal static let sqlType = UTType(filenameExtension: "sql") ?? .plainText

    internal static var readableContentTypes: [UTType] { [sqlType, .plainText] }

    internal let text: String

    internal init(text: String) {
        self.text = text
    }

    internal init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let decoded = String(bytes: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = decoded
    }

    internal func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
