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
        PaneNoticeBar(severity: .warning, onDismiss: onDismiss) {
            Text(message)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(message)
        } actions: {
            actionButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("source-file-disk-change-banner")
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
            Button(String(localized: "Reload"), action: onReload)
        case .missing:
            Button(String(localized: "Save As…"), action: onSaveAs)
        }
    }
}
