//
//  SourceFileDiskChangeBanner.swift
//  TablePro
//

import SwiftUI

internal struct SourceFileDiskChangeBanner: View {
    let fileName: String
    let change: SourceFileDiskChange
    let onReload: () -> Void
    let onSaveAs: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            Text(message)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            actionButton
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
        .background(.yellow.opacity(0.12))
    }

    private var message: String {
        switch change {
        case .modified:
            return String(format: String(localized: "\"%@\" was modified on disk."), fileName)
        case .missing:
            return String(format: String(localized: "\"%@\" was deleted or moved."), fileName)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch change {
        case .modified:
            Button(String(localized: "Reload")) {
                onReload()
            }
        case .missing:
            Button(String(localized: "Save As…")) {
                onSaveAs()
            }
        }
    }
}
