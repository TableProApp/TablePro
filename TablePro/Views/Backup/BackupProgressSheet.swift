//
//  BackupProgressSheet.swift
//  TablePro
//
//  Shared progress sheet for the backup and restore flows.
//

import SwiftUI

struct BackupProgressSheet: View {
    enum Kind {
        case backup
        case restore
    }

    let kind: Kind
    let database: String
    /// Bytes processed so far. For `.backup` this is the dump file size on disk.
    let bytesWritten: Int64
    /// Upper bound used to render a determinate bar. For backup this is
    /// `pg_database_size`, which over-estimates the dump file (compression),
    /// so the bar is capped at ~95% until the process exits. `nil` keeps the
    /// bar indeterminate (used for restore).
    let totalBytes: Int64?
    let isCancelling: Bool
    let onCancel: () -> Void

    @State private var showCancelConfirmation = false

    var body: some View {
        VStack(spacing: 20) {
            Text(titleString)
                .font(.title3.weight(.semibold))

            VStack(spacing: 8) {
                HStack {
                    Text(database)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if kind == .backup {
                        Text(byteCountString)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                progressBar
            }

            HStack(spacing: 8) {
                if isCancelling {
                    ProgressView().controlSize(.small)
                    Text("Cancelling\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Cancel") {
                        showCancelConfirmation = true
                    }
                    .frame(width: 100)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled()
        .alert(cancelAlertTitle, isPresented: $showCancelConfirmation) {
            Button(keepGoingLabel, role: .cancel) { }
            Button(cancelAlertConfirmLabel, role: .destructive) { onCancel() }
        } message: {
            Text(cancelAlertMessage)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let totalBytes, totalBytes > 0 {
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    /// Bytes / totalBytes, capped at 0.95 so the bar doesn't appear "done" while
    /// pg_dump is still finalizing the archive trailer.
    private var progressFraction: Double {
        guard let totalBytes, totalBytes > 0 else { return 0 }
        let raw = Double(bytesWritten) / Double(totalBytes)
        return min(raw, 0.95)
    }

    private var keepGoingLabel: String {
        switch kind {
        case .backup: return String(localized: "Keep Backing Up")
        case .restore: return String(localized: "Keep Restoring")
        }
    }

    private var titleString: String {
        switch kind {
        case .backup: return String(localized: "Creating Backup Dump")
        case .restore: return String(localized: "Restoring Dump")
        }
    }

    private var cancelAlertTitle: String {
        switch kind {
        case .backup: return String(localized: "Cancel Backup Dump?")
        case .restore: return String(localized: "Cancel Restore Dump?")
        }
    }

    private var cancelAlertConfirmLabel: String {
        switch kind {
        case .backup: return String(localized: "Cancel Backup Dump")
        case .restore: return String(localized: "Cancel Restore Dump")
        }
    }

    private var cancelAlertMessage: String {
        switch kind {
        case .backup: return String(localized: "The partial backup file will be removed.")
        case .restore: return String(localized: "The target database may be left in a partial state.")
        }
    }

    private var byteCountString: String {
        ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
    }
}

#Preview("Backup determinate") {
    BackupProgressSheet(
        kind: .backup,
        database: "production",
        bytesWritten: 12_345_678,
        totalBytes: 50_000_000,
        isCancelling: false,
        onCancel: {}
    )
}

#Preview("Backup indeterminate") {
    BackupProgressSheet(
        kind: .backup,
        database: "production",
        bytesWritten: 12_345_678,
        totalBytes: nil,
        isCancelling: false,
        onCancel: {}
    )
}

#Preview("Restore") {
    BackupProgressSheet(
        kind: .restore,
        database: "production",
        bytesWritten: 0,
        totalBytes: nil,
        isCancelling: false,
        onCancel: {}
    )
}
