//
//  SuggestionContentView.swift
//  CodeEditSourceEditor
//
//  Created by Claude on 2026-03-19.
//

import AppKit
import SwiftUI

struct SuggestionContentView: View {
    static let rowHeight: CGFloat = 26

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
        .contentShape(Rectangle())
        .onTapGesture {
            model.onBackgroundTap?()
        }
    }

    /// Rows live in a plain `ScrollView`/`LazyVStack`, never a `List`. `List` is backed by a
    /// focusable `NSTableView`, and AppKit's attempt to focus it when the panel appears asked
    /// the panel to become key, resigning the editor window's key status with no successor
    /// (issue #1885). Selection, arrow keys, and taps are all model-driven, so the popup's
    /// content must stay display-only chrome with no focus participation at all.
    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        suggestionRow(index: index, item: item)
                    }
                }
            }
            .padding(.vertical, SuggestionController.WINDOW_PADDING)
            .frame(height: listMaxHeight)
            .onChange(of: model.selectedIndex) { newIndex in
                withAnimation(.easeInOut(duration: 0.1)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func suggestionRow(index: Int, item: CodeSuggestionEntry) -> some View {
        CodeSuggestionLabelView(
            suggestion: item,
            labelColor: model.themeTextColor,
            secondaryLabelColor: model.themeTextColor.withAlphaComponent(0.5),
            font: model.activeTextView?.font ?? .systemFont(ofSize: 12),
            isSelected: index == model.selectedIndex
        )
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(index == model.selectedIndex
                      ? Color(nsColor: .selectedContentBackgroundColor)
                      : Color.clear)
                .padding(.horizontal, SuggestionController.WINDOW_PADDING)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            model.selectedIndex = index
        }
        .onTapGesture(count: 2) {
            model.selectedIndex = index
            if let selectedItem = model.selectedItem {
                model.applySelectedItem(item: selectedItem)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(index == model.selectedIndex ? .isSelected : [])
        .id(index)
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
        let visibleRows = min(CGFloat(model.items.count), SuggestionController.MAX_VISIBLE_ROWS)
        return Self.rowHeight * visibleRows + SuggestionController.WINDOW_PADDING * 2
    }

    private var noCompletionsView: some View {
        Text("No Completions")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
}
