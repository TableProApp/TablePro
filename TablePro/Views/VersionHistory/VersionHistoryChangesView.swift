//
//  VersionHistoryChangesView.swift
//  TablePro
//

import SwiftUI

internal struct VersionHistoryChangesView: View {
    let detail: VersionHistoryDetail
    let layout: TextDiffLayout
    let databaseType: DatabaseType
    let exportFileName: String
    let onOpenInEditor: (String) -> Void

    var body: some View {
        if let comparison = detail.comparison {
            switch comparison.outcome {
            case .identical:
                UnavailableStateView(
                    String(localized: "No Changes"),
                    systemImage: "equal.circle",
                    description: Text(String(
                        format: String(localized: "This version matches %@."),
                        VersionHistoryFormatting.shortLabel(for: detail.entry.isCurrent ? comparison.older : comparison.newer)
                    ))
                )
            case .tooLarge:
                VStack(spacing: 0) {
                    Text("This version is too large to compare. Showing its content instead.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                    VersionHistoryContentView(
                        content: detail.content,
                        databaseType: databaseType,
                        exportFileName: exportFileName,
                        onOpenInEditor: onOpenInEditor
                    )
                }
            case .differs(let pairs):
                ScrollView {
                    TextDiffView(
                        pairs: pairs,
                        beforeLabel: VersionHistoryFormatting.shortLabel(for: comparison.older),
                        afterLabel: VersionHistoryFormatting.shortLabel(for: comparison.newer),
                        layout: layout,
                        textFont: .system(.body, design: .monospaced)
                    )
                    .padding(12)
                }
                .accessibilityIdentifier("version-history-diff")
            }
        } else {
            UnavailableStateView(
                String(localized: "No Earlier Version"),
                systemImage: "clock",
                description: Text("There is nothing earlier to compare this version with.")
            )
        }
    }
}
