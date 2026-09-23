//
//  RecentTabSwitcherView.swift
//  TablePro
//

import SwiftUI

internal enum RecentTabSwitcherMetrics {
    static let width: CGFloat = 480
    static let rowHeight: CGFloat = 40
}

/// The list Control-Tab walks, drawn on the same surface as Open Quickly so the app has one kind of
/// floating panel. It takes no clicks and no focus: the chord held in the window behind it drives
/// it, and holding Control turns a click into a secondary click anyway.
internal struct RecentTabSwitcherView: View {
    @ObservedObject var model: RecentTabSwitcherModel

    var body: some View {
        QuickSwitcherGlassGroup {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.session.candidates.enumerated()), id: \.element.id) { index, candidate in
                            RecentTabSwitcherRow(
                                candidate: candidate,
                                isHighlighted: index == model.session.highlightedIndex
                            )
                            .id(candidate.id)
                        }
                    }
                    .padding(.vertical, QuickSwitcherMetrics.listVerticalPadding)
                }
                .frame(height: listHeight)
                .onAppear { proxy.scrollTo(model.session.highlighted.id) }
                .onValueChange(of: model.session.highlightedIndex) { _, _ in
                    proxy.scrollTo(model.session.highlighted.id)
                }
            }
            .frame(width: RecentTabSwitcherMetrics.width)
            .quickSwitcherSurface(cornerRadius: QuickSwitcherMetrics.cornerRadius)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Recent Tabs"))
    }

    private var listHeight: CGFloat {
        let visibleRows = min(model.session.candidates.count, QuickSwitcherMetrics.maxVisibleRows)
        return CGFloat(visibleRows) * RecentTabSwitcherMetrics.rowHeight + QuickSwitcherMetrics.listVerticalPadding * 2
    }
}
