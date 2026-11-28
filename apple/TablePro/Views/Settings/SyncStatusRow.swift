//
//  SyncStatusRow.swift
//  TablePro
//

import SwiftUI

// The Sync pane's Status row, for iCloud and for TablePro Sync alike.
struct SyncStatusRow: View {
    let title: String
    let symbolName: String
    let isWarning: Bool
    let isBusy: Bool
    let detail: String?

    var body: some View {
        LabeledContent {
            // First baseline keeps the value on the label's baseline while the spinner shows.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: symbolName)
                        .foregroundStyle(isWarning ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                }

                // A grouped form keeps the accessibility value a text was first given, so each title is a text of its own.
                Text(title)
                    .id(title)
                    .accessibilityIdentifier("settings-sync-status")
            }
        } label: {
            Text("Status")
            if let detail {
                Text(detail)
            }
        }
    }
}
