//
//  ExportSuccessView.swift
//  TablePro
//
//  Success dialog shown after export completes.
//  Provides option to open containing folder in Finder.
//

import SwiftUI

/// Success dialog shown after export completes
struct ExportSuccessView: View {
    let onOpenFolder: () -> Void
    let onClose: () -> Void

    @AppStorage("hideExportSuccessDialog") private var dontShowAgain = false
    @State private var localDontShowAgain = false

    init(onOpenFolder: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onOpenFolder = onOpenFolder
        self.onClose = onClose
    }
    var body: some View {
        VStack(spacing: 20) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color(nsColor: .systemGreen))

            // Title and message
            VStack(spacing: 6) {
                Text("Success")
                    .font(.title3.weight(.semibold))

                Text("Export completed successfully")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            // Buttons
            VStack(spacing: 10) {
                Button("Open containing folder") {
                    onOpenFolder()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Close") {
                    if localDontShowAgain {
                        dontShowAgain = true
                    }
                    onClose()
                }
                .controlSize(.large)
            }

            // Don't show again checkbox
            Toggle("Don't show this again", isOn: $localDontShowAgain)
                .toggleStyle(.checkbox)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Preview

#Preview {
    ExportSuccessView(
        onOpenFolder: {},
        onClose: {}
    )
}
