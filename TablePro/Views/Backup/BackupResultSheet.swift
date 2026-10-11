//
//  BackupResultSheet.swift
//  TablePro
//
//  Shared result sheet for the backup and restore flows.
//

import SwiftUI

struct BackupResultSheet: View {
    enum Kind {
        case backup
        case restore
    }

    enum Outcome {
        case backupSuccess(database: String, destination: URL, bytes: Int64)
        case restoreSuccess(database: String, source: URL, skippedSettings: [String])
        /// A run over several databases, where one failing does not stop the rest, so the sheet
        /// reports every database rather than one verdict for the batch.
        case batch(outcomes: [NativeDumpBatchOutcome], directory: URL)
        case failure(message: String, targetMayBeModified: Bool)
        case cancelled
    }

    let kind: Kind
    let outcome: Outcome
    let onClose: () -> Void
    let onShowInFinder: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            icon
                .font(.system(size: 36))
                .foregroundStyle(tintColor)

            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            detailView

            HStack(spacing: 12) {
                if showsFinderButton, let onShowInFinder {
                    Button(String(localized: "Show in Finder")) {
                        onShowInFinder()
                        onClose()
                    }
                }
                Button(String(localized: "Done")) {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var showsFinderButton: Bool {
        switch outcome {
        case .backupSuccess: return true
        case .batch(let outcomes, _): return outcomes.contains(where: \.succeeded)
        case .restoreSuccess, .failure, .cancelled: return false
        }
    }

    private static let partialStateWarning = String(
        localized: "The target database may be in a partial state. Review it and clean up as needed.")

    @ViewBuilder
    private var detailView: some View {
        switch outcome {
        case .failure(let message, let targetMayBeModified):
            if targetMayBeModified {
                Text(Self.partialStateWarning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            scrollingDetail(message)
        case .batch(let outcomes, let directory):
            batchDetailView(outcomes, directory: directory)
        case .restoreSuccess(_, _, let skippedSettings):
            summaryDetail
            if let note = Self.skippedSettingsNote(skippedSettings) {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .textSelection(.enabled)
            }
        default:
            summaryDetail
        }
    }

    @ViewBuilder
    private var summaryDetail: some View {
        if let detail {
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .center)
                .textSelection(.enabled)
        }
    }

    /// The folder is a labelled row and each database is its own row, because one text block made
    /// the folder and the first database read as a single path (#3046).
    private func batchDetailView(_ outcomes: [NativeDumpBatchOutcome], directory: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent {
                Text(directory.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } label: {
                Text("Destination")
            }
            .font(.callout)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(BackupOutcomeRow.rows(for: outcomes)) { row in
                        outcomeRow(row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    private func outcomeRow(_ row: BackupOutcomeRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbolName(for: row.state))
                    .foregroundStyle(Self.tint(for: row.state))
                    .accessibilityLabel(Self.stateAccessibilityLabel(for: row.state))
                Text(row.database)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(Self.stateLabel(for: row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorDetail = row.errorDetail {
                RevealedTextView(errorDetail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if row.state == .succeeded {
                Text(row.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private static func symbolName(for state: BackupOutcomeRow.State) -> String {
        switch state {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private static func tint(for state: BackupOutcomeRow.State) -> Color {
        switch state {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    /// A successful row's trailing text is its size, so without this the state reaches VoiceOver
    /// through the symbol's colour alone.
    private static func stateAccessibilityLabel(for state: BackupOutcomeRow.State) -> String {
        switch state {
        case .succeeded: return String(localized: "Backed up")
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }

    internal static func stateLabel(for row: BackupOutcomeRow) -> String {
        switch row.state {
        case .succeeded: return row.size ?? ""
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }

    private func scrollingDetail(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 160)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var icon: some View {
        switch outcome {
        case .backupSuccess, .restoreSuccess:
            Image(systemName: "checkmark.circle.fill")
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
        case .batch(let outcomes, _):
            Image(systemName: Self.batchAllSucceeded(outcomes)
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill")
        }
    }

    private static func batchAllSucceeded(_ outcomes: [NativeDumpBatchOutcome]) -> Bool {
        !outcomes.isEmpty && outcomes.allSatisfy(\.succeeded)
    }

    private var tintColor: Color {
        switch outcome {
        case .backupSuccess, .restoreSuccess: return .green
        case .failure: return .orange
        case .cancelled: return .gray
        case .batch(let outcomes, _): return Self.batchAllSucceeded(outcomes) ? .green : .orange
        }
    }

    private var title: String {
        switch outcome {
        case .backupSuccess:
            return String(localized: "Backup Dump Complete")
        case .restoreSuccess:
            return String(localized: "Restore Dump Complete")
        case .failure:
            switch kind {
            case .backup: return String(localized: "Backup Dump Failed")
            case .restore: return String(localized: "Restore Dump Failed")
            }
        case .cancelled:
            switch kind {
            case .backup: return String(localized: "Backup Dump Cancelled")
            case .restore: return String(localized: "Restore Dump Cancelled")
            }
        case .batch(let outcomes, _):
            guard !Self.batchAllSucceeded(outcomes) else {
                return String(localized: "Backup Dump Complete")
            }
            return String(localized: "Backup Dump Finished With Problems")
        }
    }

    private var detail: String? {
        switch outcome {
        case .backupSuccess(let database, let destination, let bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return String(
                format: String(localized: "Saved %@ of \u{201C}%@\u{201D} to %@"),
                size,
                database,
                destination.path
            )
        case .restoreSuccess(let database, let source, _):
            return String(
                format: String(localized: "Restored \u{201C}%@\u{201D} from %@"),
                database,
                source.path
            )
        case .failure(let message, _):
            return message
        case .cancelled:
            switch kind {
            case .backup: return nil
            case .restore:
                return Self.partialStateWarning
            }
        case .batch:
            return nil
        }
    }

    internal static func skippedSettingsNote(_ settings: [String]) -> String? {
        guard let first = settings.first else { return nil }
        guard settings.count > 1 else {
            return String(
                format: String(localized: "Skipped the %@ setting, which this server does not recognize."),
                first
            )
        }
        return String(
            format: String(localized: "Skipped settings this server does not recognize: %@."),
            settings.formatted(.list(type: .and))
        )
    }
}

#Preview("Backup Success") {
    BackupResultSheet(
        kind: .backup,
        outcome: .backupSuccess(
            database: "production",
            destination: URL(fileURLWithPath: "/Users/me/Desktop/production-2025-05-11-120000.dump"),
            bytes: 12_345_678
        ),
        onClose: {},
        onShowInFinder: {}
    )
}

#Preview("Restore Success") {
    BackupResultSheet(
        kind: .restore,
        outcome: .restoreSuccess(
            database: "production",
            source: URL(fileURLWithPath: "/Users/me/Desktop/production.dump"),
            skippedSettings: []
        ),
        onClose: {},
        onShowInFinder: nil
    )
}

#Preview("Restore Success With Skipped Settings") {
    BackupResultSheet(
        kind: .restore,
        outcome: .restoreSuccess(
            database: "production",
            source: URL(fileURLWithPath: "/Users/me/Desktop/production.dump"),
            skippedSettings: ["idle_in_transaction_session_timeout", "transaction_timeout"]
        ),
        onClose: {},
        onShowInFinder: nil
    )
}

#Preview("Backup Batch With A Failure") {
    BackupResultSheet(
        kind: .backup,
        outcome: .batch(
            outcomes: [
                NativeDumpBatchOutcome(
                    database: "Music",
                    destination: URL(fileURLWithPath: "/Users/me/Music/New/Music-2026-09-21-181500.sql"),
                    result: .failed(
                        message: "/opt/homebrew/bin/mysqldump: unknown variable 'ssl-mode=PREFERRED'")
                ),
                NativeDumpBatchOutcome(
                    database: "production",
                    destination: URL(fileURLWithPath: "/Users/me/Music/New/production-2026-09-21-181500.sql"),
                    result: .succeeded(bytes: 4_512_000)
                ),
                NativeDumpBatchOutcome(
                    database: "analytics",
                    destination: URL(fileURLWithPath: "/Users/me/Music/New/analytics-2026-09-21-181500.sql"),
                    result: .cancelled
                )
            ],
            directory: URL(fileURLWithPath: "/Users/me/Music/New", isDirectory: true)
        ),
        onClose: {},
        onShowInFinder: {}
    )
}

#Preview("Restore Failure") {
    BackupResultSheet(
        kind: .restore,
        outcome: .failure(
            message: "pg_restore: error: could not connect to database \"missing\": FATAL: database does not exist",
            targetMayBeModified: true),
        onClose: {},
        onShowInFinder: nil
    )
}
