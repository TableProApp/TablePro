//
//  OutdatedPageNoticeBar.swift
//  TablePro
//

import SwiftUI

internal struct OutdatedPageNoticeBar: View {
    let tableName: String
    let onReload: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        PaneNoticeBar(severity: .warning, onDismiss: onDismiss) {
            Text(message)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(message)
        } actions: {
            Button(String(localized: "Reload"), action: onReload)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outdated-page-notice")
    }

    private var message: String {
        String(format: String(localized: "The structure of \"%@\" changed. Reload to show its current columns."), tableName)
    }
}

#Preview {
    OutdatedPageNoticeBar(tableName: "orders", onReload: {}, onDismiss: {})
        .frame(width: 640)
}
