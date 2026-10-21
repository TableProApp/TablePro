//
//  GenerateRowsSheet.swift
//  TablePro
//

import SwiftUI

internal struct GenerateRowsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject internal var session: RowGenerationSession
    @State private var scriptError: String?

    internal init(session: RowGenerationSession) {
        self.session = session
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 820, height: 640)
        .interactiveDismissDisabled(session.phase == .running)
        .task { await session.loadIfNeeded() }
        .alert(
            String(localized: "Could Not Write the Statements"),
            isPresented: Binding(get: { scriptError != nil }, set: { if !$0 { scriptError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(scriptError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Generate Rows"))
                .font(.title3.weight(.semibold))
            Text(String(format: String(localized: "%1$@ in %2$@"), session.tableName, session.scopeDescription))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            ProgressView(String(localized: "Reading the table…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loadFailed(let message):
            VStack(spacing: 8) {
                Text(String(localized: "Could not read the table."))
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .configuring:
            GenerateRowsConfigureView(session: session)
        case .running:
            progress
        case .finished(let outcome):
            GenerateRowsResultView(outcome: outcome, tableName: session.tableName, seed: session.lastRunSeed)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inserted \(session.writtenRows) of ^[\(session.targetRows) row](inflect: true)…")
                .monospacedDigit()
            ProgressView(value: session.progressFraction)
                .progressViewStyle(.linear)
                .accessibilityIdentifier("generate-rows-progress")
            Text(String(localized: "The rows go in as one transaction. Cancel rolls it back."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        DialogFooter {
            statusText
        } actions: {
            actionButtons
        }
        .padding(20)
    }

    @ViewBuilder
    private var statusText: some View {
        if session.phase == .configuring, let issue = session.issues.first {
            Label(issue.message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("generate-rows-issue")
        } else if session.phase == .configuring, !session.canOpenScript, session.canGenerate {
            Text(String(
                format: String(localized: "Open in Query Editor takes up to %@ rows."),
                RowGenerationSession.scriptRowLimit.formatted(.number.grouping(.automatic))
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch session.phase {
        case .loading, .loadFailed:
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
        case .configuring:
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Open in Query Editor")) { openScript() }
                .disabled(!session.canOpenScript)
                .accessibilityIdentifier("generate-rows-open-script")
            Button(String(localized: "Generate")) { session.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canGenerate)
                .accessibilityIdentifier("generate-rows-start")
        case .running:
            Button(String(localized: "Cancel")) { session.cancel() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("generate-rows-cancel")
        case .finished:
            Button(String(localized: "Edit Settings")) { session.editSettings() }
                .accessibilityIdentifier("generate-rows-edit")
            Button(String(localized: "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("generate-rows-done")
        }
    }

    private func openScript() {
        do {
            try session.openScript()
        } catch {
            scriptError = error.localizedDescription
        }
    }
}

internal struct GenerateRowsResultView: View {
    internal let outcome: RowGenerationOutcome
    internal let tableName: String
    internal let seed: UInt64?

    internal var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            title
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("generate-rows-result")
            switch outcome {
            case .inserted:
                if let seed {
                    Text("Seed \(String(seed)) made these rows. The next run starts from a new seed.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            case .cancelled(let kept):
                keptText(kept)
                    .foregroundStyle(.secondary)
            case .failed(let message, let kept):
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                keptText(kept)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch outcome {
        case .inserted: "checkmark.circle"
        case .cancelled: "stop.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var title: Text {
        switch outcome {
        case .inserted(let count):
            Text("Inserted ^[\(count) row](inflect: true) into \(tableName).")
        case .cancelled:
            Text("Stopped.")
        case .failed:
            Text("The rows could not be inserted.")
        }
    }

    private func keptText(_ kept: Int) -> Text {
        guard kept > 0 else { return Text("The transaction was rolled back, so no rows were added.") }
        return Text("It stopped after adding ^[\(kept) row](inflect: true).")
    }
}
