//
//  BackupProgressSheet.swift
//  TablePro
//

import SwiftUI

struct BackupProgressSheet: View {
    let database: String
    let bytesWritten: Int64
    let isCancelling: Bool
    let onCancel: () -> Void

    @State private var showCancelConfirmation = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Backing Up Database")
                .font(.title3.weight(.semibold))

            VStack(spacing: 8) {
                HStack {
                    Text(database)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(byteCountString)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
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
        .alert(String(localized: "Cancel Backup?"), isPresented: $showCancelConfirmation) {
            Button(String(localized: "Continue"), role: .cancel) { }
            Button(String(localized: "Cancel Backup"), role: .destructive) { onCancel() }
        } message: {
            Text("The partial backup file will be removed.")
        }
    }

    private var byteCountString: String {
        ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
    }
}

#Preview {
    BackupProgressSheet(
        database: "production",
        bytesWritten: 12_345_678,
        isCancelling: false,
        onCancel: {}
    )
}
