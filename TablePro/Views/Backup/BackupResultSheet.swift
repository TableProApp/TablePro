//
//  BackupResultSheet.swift
//  TablePro
//

import SwiftUI

struct BackupResultSheet: View {
    enum Outcome {
        case success(database: String, destination: URL, bytes: Int64)
        case failure(message: String)
        case cancelled
    }

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

            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                if case .success = outcome, let onShowInFinder {
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
    private var icon: some View {
        switch outcome {
        case .success:
            Image(systemName: "checkmark.circle.fill")
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
        }
    }

    private var tintColor: Color {
        switch outcome {
        case .success: return Color(nsColor: .systemGreen)
        case .failure: return Color(nsColor: .systemOrange)
        case .cancelled: return Color(nsColor: .systemGray)
        }
    }

    private var title: String {
        switch outcome {
        case .success: return String(localized: "Backup Complete")
        case .failure: return String(localized: "Backup Failed")
        case .cancelled: return String(localized: "Backup Cancelled")
        }
    }

    private var detail: String? {
        switch outcome {
        case .success(let database, let destination, let bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return String(
                format: String(localized: "Saved %@ of \u{201C}%@\u{201D} to %@"),
                size,
                database,
                destination.path
            )
        case .failure(let message):
            return message
        case .cancelled:
            return nil
        }
    }
}

#Preview("Success") {
    BackupResultSheet(
        outcome: .success(
            database: "production",
            destination: URL(fileURLWithPath: "/Users/me/Desktop/production-2025-05-11-120000.dump"),
            bytes: 12_345_678
        ),
        onClose: {},
        onShowInFinder: {}
    )
}

#Preview("Failure") {
    BackupResultSheet(
        outcome: .failure(message: "pg_dump: error: connection to server failed: FATAL: password authentication failed for user \"postgres\""),
        onClose: {},
        onShowInFinder: nil
    )
}
