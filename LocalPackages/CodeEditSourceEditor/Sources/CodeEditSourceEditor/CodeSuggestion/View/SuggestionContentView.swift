//
//  SuggestionContentView.swift
//  CodeEditSourceEditor
//
//  Created by Claude on 2026-03-19.
//

import AppKit
import SwiftUI

struct SuggestionContentView: View {
    @ObservedObject var model: SuggestionViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                noCompletionsView
            } else {
                suggestionList
                if let item = model.selectedItem,
                   item.documentation != nil || item.sourcePreview != nil
                       || (item.pathComponents != nil && !(item.pathComponents?.isEmpty ?? true)) {
                    Divider()
                    SuggestionPreviewView(
                        item: item,
                        syntaxHighlight: model.syntaxHighlights(forIndex: model.selectedIndex),
                        font: model.activeTextView?.font ?? .systemFont(ofSize: 12)
                    )
                }
            }
        }
        .frame(width: contentWidth)
        .background(Color(nsColor: model.themeBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8.5))
    }

    private var suggestionList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                    CodeSuggestionLabelView(
                        suggestion: item,
                        labelColor: model.themeTextColor,
                        secondaryLabelColor: model.themeTextColor.withAlphaComponent(0.5),
                        font: model.activeTextView?.font ?? .systemFont(ofSize: 12),
                        isSelected: index == model.selectedIndex
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1) {
                        model.selectedIndex = index
                    }
                    .onTapGesture(count: 2) {
                        model.selectedIndex = index
                        if let selectedItem = model.selectedItem {
                            model.applySelectedItem(
                                item: selectedItem,
                                window: model.activeTextView?.view.window
                            )
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(index == model.selectedIndex
                                  ? Color(nsColor: .selectedContentBackgroundColor)
                                  : Color.clear)
                            .padding(.horizontal, SuggestionController.WINDOW_PADDING)
                    )
                    .listRowSeparator(.hidden)
                    .id(index)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.vertical, SuggestionController.WINDOW_PADDING)
            .frame(height: listMaxHeight)
            .onChange(of: model.selectedIndex) { newIndex in
                withAnimation(.easeInOut(duration: 0.1)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private var contentWidth: CGFloat {
        let font = model.activeTextView?.font ?? NSFont.systemFont(ofSize: 12)
        let iconWidth = font.pointSize + 6
        let maxLabelLength = min(
            model.items.reduce(0) { current, item in
                let labelLen = (item.label as NSString).length
                let detailLen = ((item.detail ?? "") as NSString).length
                return max(current, labelLen + detailLen)
            } + 2,
            64
        )
        let textWidth = CGFloat(maxLabelLength) * font.charWidth
        return max(iconWidth + textWidth + CodeSuggestionLabelView.HORIZONTAL_PADDING * 2, 280)
    }

    private var listMaxHeight: CGFloat {
        let rowHeight: CGFloat = 26
        let visibleRows = min(CGFloat(model.items.count), SuggestionController.MAX_VISIBLE_ROWS)
        return rowHeight * visibleRows + SuggestionController.WINDOW_PADDING * 2
    }

    private var noCompletionsView: some View {
        Text("No Completions")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
}
