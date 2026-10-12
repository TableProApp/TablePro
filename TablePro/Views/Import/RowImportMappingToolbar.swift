//
//  RowImportMappingToolbar.swift
//  TablePro
//

import SwiftUI

/// One-shot commands rather than a mode, which would stop describing the mapping after one manual edit.
struct RowImportMappingToolbar: View {
    @ObservedObject var mapping: RowImportMapping
    let tableName: String
    let fieldsFollowFileOrder: Bool

    var body: some View {
        HStack(spacing: 8) {
            if mapping.showsSavedMapping {
                Text(String(format: String(localized: "Restored the mapping saved for %@."), tableName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Menu(String(localized: "Match Columns")) {
                Button(String(localized: "Match by Name"), action: mapping.matchByName)
                Button(String(localized: "Match by Position"), action: mapping.matchByPosition)
                    .disabled(!fieldsFollowFileOrder)
                Divider()
                Button(String(localized: "Use Saved Mapping"), action: mapping.useSavedMapping)
                    .disabled(!mapping.canUseSavedMapping)
            }
            .fixedSize()
            .accessibilityIdentifier("row-import-match-columns")
        }
    }
}
