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
    /// Number of bytes written so far. Only shown for `.backup`; ignored for `.restore`.
    let bytesWritten: Int64
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

                ProgressView()
                    .progressViewStyle(.linear)
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
            Button(String(localized: "Continue"), role: .cancel) { }
            Button(cancelAlertConfirmLabel, role: .destructive) { onCancel() }
        } message: {
            Text(cancelAlertMessage)
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

#Preview("Backup") {
    BackupProgressSheet(
        kind: .backup,
        database: "production",
        bytesWritten: 12_345_678,
        isCancelling: false,
        onCancel: {}
    )
}

#Preview("Restore") {
    BackupProgressSheet(
        kind: .restore,
        database: "production",
        bytesWritten: 0,
        isCancelling: false,
        onCancel: {}
    )
}
