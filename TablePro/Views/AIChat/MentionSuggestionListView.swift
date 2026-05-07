//
//  MentionSuggestionListView.swift
//  TablePro
//

import SwiftUI

struct MentionSuggestionListView: View {
    @Bindable var state: MentionPopoverState
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.candidates.enumerated()), id: \.element.id) { index, candidate in
                MentionRowView(
                    candidate: candidate,
                    isSelected: index == state.selectedIndex
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect(index) }
                .onHover { hovering in
                    if hovering { state.selectedIndex = index }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 280)
    }
}

private struct MentionRowView: View {
    let candidate: MentionCandidate
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: candidate.symbolName)
                .frame(width: 14, alignment: .center)
                .foregroundStyle(isSelected ? Color.white : .secondary)
            Text(candidate.displayLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.white : .primary)
            Spacer(minLength: 4)
            if let secondary = candidate.secondaryLabel {
                Text(secondary)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? Color(nsColor: .selectedContentBackgroundColor)
                : Color.clear
        )
    }
}
