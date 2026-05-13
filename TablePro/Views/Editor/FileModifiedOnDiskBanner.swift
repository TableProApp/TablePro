//
//  FileModifiedOnDiskBanner.swift
//  TablePro
//

import SwiftUI

internal struct FileModifiedOnDiskBanner: View {
    let fileName: String
    let onReload: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemYellow))
                .accessibilityHidden(true)

            Text(String(format: String(localized: "\"%@\" was modified on disk."), fileName))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(String(localized: "Reload")) {
                onReload()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Dismiss"))
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .systemYellow).opacity(0.12))
    }
}
