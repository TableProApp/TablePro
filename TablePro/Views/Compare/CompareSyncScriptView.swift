//
//  CompareSyncScriptView.swift
//  TablePro
//
//  The generated script and its hazards. Statements that would destroy data are
//  listed but held back until they are allowed for this run.
//

import AppKit
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

internal struct CompareSyncScriptView: View {
    @Bindable internal var session: CompareSyncSession

    @State private var isExporting = false

    internal var body: some View {
        HSplitView {
            hazardPane
                .frame(minWidth: 300, idealWidth: 340)
            scriptPane
                .frame(minWidth: 400)
        }
    }

    private var heldBack: [SyncStatement] {
        session.statements.filter { $0.isRefusedByDefault }
    }

    private var hazardPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Warnings")
                    .font(.headline)
                Spacer()
                if !heldBack.isEmpty {
                    Text("\(allowedCount)/\(heldBack.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if heldBack.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text("Nothing in this script destroys data.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        Text("These are held back. Allow one to include it in this run only; the choice is never saved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(heldBack) { statement in
                        HeldBackStatementRow(statement: statement, session: session)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            executionSettings
        }
    }

    private var allowedCount: Int {
        heldBack.filter { session.executionSettings.allowedHazardStatementIds.contains($0.id) }.count
    }

    private var executionSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(String(localized: "On error"), selection: $session.executionSettings.errorHandling) {
                Text("Stop and roll back").tag(ImportErrorHandling.stopAndRollback)
                Text("Stop and keep what ran").tag(ImportErrorHandling.stopAndCommit)
                Text("Skip and continue").tag(ImportErrorHandling.skipAndContinue)
            }

            Toggle(String(localized: "Run in a transaction"), isOn: $session.executionSettings.wrapInTransaction)
                .disabled(session.executionSettings.errorHandling == .skipAndContinue)

            if session.executionSettings.errorHandling == .skipAndContinue {
                Text("A transaction cannot be used with skip and continue, because together they leave the target half-applied.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var scriptPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Script")
                    .font(.headline)
                Text("\(session.statements.count) statements")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Copy")) { copyScript() }
                Button(String(localized: "Save...")) { isExporting = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            TextEditor(text: scriptBinding)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: SyncScriptDocument(text: scriptBinding.wrappedValue),
            contentType: SyncScriptDocument.sqlType,
            defaultFilename: "sync"
        ) { _ in }
    }

    private var scriptBinding: Binding<String> {
        Binding(
            get: { session.editedScript ?? session.statements.map { $0.sql }.joined(separator: "\n") },
            set: { session.editedScript = $0 }
        )
    }

    private func copyScript() {
        ClipboardService.shared.writeText(scriptBinding.wrappedValue)
    }
}

internal struct HeldBackStatementRow: View {
    internal let statement: SyncStatement
    @Bindable internal var session: CompareSyncSession

    internal var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: allowBinding) {
                Text(statement.summary)
                    .font(.callout)
            }
            ForEach(statement.hazards) { hazard in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hazard.kind.displayName)
                            .font(.caption.weight(.semibold))
                        Text(hazard.explanation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Text(statement.sql)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }

    private var allowBinding: Binding<Bool> {
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
