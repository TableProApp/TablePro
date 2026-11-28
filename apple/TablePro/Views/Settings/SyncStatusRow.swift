//
//  SyncStatusRow.swift
//  TablePro
//

import SwiftUI

// The Sync pane's Status row, for iCloud and for TablePro Sync alike. Review opens the changes waiting for approval.
struct SyncStatusRow: View {
    let title: String
    let symbolName: String
    let isWarning: Bool
    let isBusy: Bool
    let detail: String?
    var review: (() -> Void)?

    var body: some View {
        LabeledContent {
            // Review goes under the status, so the count never truncates in the pane's width.
            VStack(alignment: .trailing, spacing: 6) {
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
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-sync-status")
                }

                if let review {
                    Button(String(localized: "Review…"), action: review)
                        .accessibilityHint(Text("Shows the changes from your other devices that wait for your approval"))
                        .accessibilityIdentifier("settings-sync-review-approvals")
                }
            }
        } label: {
            Text("Status")
            if let detail {
                Text(detail)
            }
        }
    }
}
