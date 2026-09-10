//
//  MentionSuggestionListView.swift
//  TablePro
//

import SwiftUI

struct MentionSuggestionListView: View {
    @Bindable var state: MentionPopoverState
    let onSelect: (Int) -> Void

    /// Hover is its own state rather than a write into `selectedIndex`. Driving the selection from
    /// the pointer let a mouse resting over the list silently overwrite an arrow-key choice, and
    /// Return then committed a row the user never picked.
    @State private var hoveredIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.candidates.enumerated()), id: \.element.id) { index, candidate in
                MentionRowView(
                    candidate: candidate,
                    isSelected: index == state.selectedIndex,
                    isHovered: index == hoveredIndex
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect(index) }
                .onHover { hovering in
                    if hovering {
                        hoveredIndex = index
                    } else if hoveredIndex == index {
                        hoveredIndex = nil
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(index == state.selectedIndex ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 280)
    }
}

private struct MentionRowView: View {
    let candidate: MentionCandidate
    let isSelected: Bool
    let isHovered: Bool

    private var primaryTextColor: Color {
        Color(nsColor: .alternateSelectedControlTextColor)
    }

    private var secondaryTextColor: Color {
        Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: candidate.symbolName)
                .frame(width: 14, alignment: .center)
                .foregroundStyle(isSelected ? primaryTextColor : .secondary)
            Text(candidate.displayLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? primaryTextColor : .primary)
            Spacer(minLength: 4)
            if let secondary = candidate.secondaryLabel {
                Text(secondary)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? secondaryTextColor : .secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
    }

    private var rowBackground: Color {
        if isSelected { return Color(nsColor: .selectedContentBackgroundColor) }
        return isHovered ? Color(nsColor: .quaternarySystemFill) : .clear
    }
}
