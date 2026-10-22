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
            QuickSwitcherList(
                rows: model.session.candidates,
                selection: model.session.highlighted.id,
                height: listHeight
            ) { candidate in
                RecentTabSwitcherRow(
                    candidate: candidate,
                    isHighlighted: candidate.id == model.session.highlighted.id
                )
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
