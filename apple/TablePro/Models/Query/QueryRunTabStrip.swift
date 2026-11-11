//
//  QueryRunTabStrip.swift
//  TablePro
//

import Foundation

/// The tab row above a query tab's results while the Message and Summary tabs are on: Message, Summary, then the
/// results. Pure, so which tab is lit and how the results fold is checked without mounting the control.
struct QueryRunTabStrip: Equatable {
    enum Segment: Equatable {
        case message
        case summary
        case result(ResultSetMenuEntry)
    }

    let segments: [Segment]
    /// -1 when no tab stands for the page in front, such as a result page with no results left.
    let selectedIndex: Int

    /// `listsEachResult` false folds the results into one tab for the active result, and the pull-down at the end of
    /// the row chooses which. The row folds when it is too narrow or the run made more results than tabs.
    init(page: ResultsPage, results: ResultSetMenuModel, listsEachResult: Bool) {
        let shown: [ResultSetMenuEntry]
        if listsEachResult {
            shown = results.entries
        } else {
            shown = (results.activeEntry ?? results.entries.last).map { [$0] } ?? []
        }
        let segments = [Segment.message, .summary] + shown.map(Segment.result)
        self.segments = segments
        switch page {
        case .message:
            selectedIndex = 0
        case .summary:
            selectedIndex = 1
        case .result:
            selectedIndex = segments.firstIndex { segment in
                guard case .result(let entry) = segment else { return false }
                return entry.isActive
            } ?? -1
        }
    }

    /// HIG, Tab views: past six result tabs the pull-down alone lists them, as it does with the run tabs off.
    static func canListEachResult(_ results: ResultSetMenuModel) -> Bool {
        results.total <= ResultSetMenuModel.maximumTabCount
    }

    static func title(of segment: Segment, in results: ResultSetMenuModel) -> String {
        switch segment {
        case .message:
            return String(localized: "Message")
        case .summary:
            return String(localized: "Summary")
        case .result(let entry):
            return results.tabTitle(of: entry)
        }
    }

    static func toolTip(of segment: Segment, in results: ResultSetMenuModel) -> String {
        switch segment {
        case .message:
            return String(localized: "What each statement of the last run did")
        case .summary:
            return String(localized: "Each statement of the last run, with its status, rows and time")
        case .result(let entry):
            return results.displayLabel(of: entry)
        }
    }
}
