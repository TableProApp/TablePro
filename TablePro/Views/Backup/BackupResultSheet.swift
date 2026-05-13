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
        case restoreSuccess(database: String, source: URL)
        case failure(message: String)
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
                if case .backupSuccess = outcome, let onShowInFinder {
                    Button(String(localized: "Show in Finder")) {
                        onShowInFinder()
                        onClose()
                    }
                }
                Button(String(localized: "Done")) {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var detailView: some View {
        switch outcome {
        case .failure(let message):
            ScrollView {
                Text(message)
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
        default:
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
        }
    }

    private var tintColor: Color {
        switch outcome {
        case .backupSuccess, .restoreSuccess: return Color(nsColor: .systemGreen)
        case .failure: return Color(nsColor: .systemOrange)
        case .cancelled: return Color(nsColor: .systemGray)
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
        case .restoreSuccess(let database, let source):
            return String(
                format: String(localized: "Restored \u{201C}%@\u{201D} from %@"),
                database,
                source.path
            )
        case .failure(let message):
            return message
        case .cancelled:
            switch kind {
            case .backup: return nil
            case .restore:
                return String(localized: "The target database may be in a partial state. Review the database and clean up as needed.")
            }
        }
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
            source: URL(fileURLWithPath: "/Users/me/Desktop/production.dump")
        ),
        onClose: {},
        onShowInFinder: nil
    )
}

#Preview("Restore Failure") {
    BackupResultSheet(
        kind: .restore,
        outcome: .failure(message: "pg_restore: error: could not connect to database \"missing\": FATAL: database does not exist"),
        onClose: {},
        onShowInFinder: nil
    )
}
