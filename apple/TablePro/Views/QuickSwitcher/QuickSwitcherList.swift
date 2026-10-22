//
//  QuickSwitcherList.swift
//  TablePro
//

import SwiftUI

/// The result list under a floating panel's field: Open Quickly, Jump to Column and the recent-tab
/// switcher. One flat `ForEach` and no `.id` on a row: a lazy stack showed a row realized under a
/// removed outer `ForEach` element at its new place and never updated it again (#3785).
internal struct QuickSwitcherList<Row: Identifiable, Content: View>: View {
    let rows: [Row]
    let selection: Row.ID?
    /// Bumped by the owner for each new search. A new search can keep the selected id while the
    /// list scrolled away from it, and a refilter of the same search must not undo a mouse scroll.
    var search = 0
    let height: CGFloat
    @ViewBuilder let content: (Row) -> Content

    private struct RevealTarget: Equatable {
        let selection: Row.ID?
        let search: Int
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        content(row)
                    }
                }
                .padding(.vertical, QuickSwitcherMetrics.listVerticalPadding)
            }
            .frame(height: height)
            .onAppear { reveal(selection, in: proxy) }
            // The deprecated `onChange` behind this runs with the old view, so only the new value is current.
            .onValueChange(of: RevealTarget(selection: selection, search: search)) { _, target in
                reveal(target.selection, in: proxy)
            }
        }
    }

    private func reveal(_ id: Row.ID?, in proxy: ScrollViewProxy) {
        guard let id else { return }
        proxy.scrollTo(id)
    }
}
