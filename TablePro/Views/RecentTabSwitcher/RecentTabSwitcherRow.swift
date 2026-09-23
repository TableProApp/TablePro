//
//  RecentTabSwitcherRow.swift
//  TablePro
//

import SwiftUI

internal struct RecentTabSwitcherRow: View {
    let candidate: RecentTabCandidate
    let isHighlighted: Bool

    private var secondary: Color {
        isHighlighted ? Color.emphasizedSelectionLabel.opacity(0.85) : Color.secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: candidate.symbolName)
                .font(.callout.weight(.medium))
                .foregroundStyle(secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(candidate.title)
                .font(.body)
                .foregroundStyle(isHighlighted ? Color.emphasizedSelectionLabel : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if !candidate.detail.isEmpty {
                Text(candidate.detail)
                    .font(.callout)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: RecentTabSwitcherMetrics.rowHeight)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: QuickSwitcherMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
                    .padding(.horizontal, QuickSwitcherMetrics.rowInset)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }
}
