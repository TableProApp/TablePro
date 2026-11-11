//
//  QueryRunTabBar.swift
//  TablePro
//

import AppKit
import SwiftUI

struct QueryRunTabActions {
    let showPage: (ResultsPage) -> Void
    /// `activate` brings the result's page to the front as well as choosing the result.
    let results: ResultSetActions

    static var none: QueryRunTabActions {
        QueryRunTabActions(showPage: { _ in }, results: .none)
    }
}

// Message, Summary and a tab per result, with the result pull-down at the end of the row. Takes the place of
// `ResultSetTabBar` while Settings > Editor turns the tabs on.
struct QueryRunTabBar: View {
    let page: ResultsPage
    let results: ResultSetMenuModel
    /// False in Structure mode, which chooses no result, as the result set tab row offers no pull-down there.
    var showsMenu = true
    let actions: QueryRunTabActions

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                if QueryRunTabStrip.canListEachResult(results) {
                    row(listsEachResult: true, isSpelledOut: true)
                    row(listsEachResult: true, isSpelledOut: false)
                }
                row(listsEachResult: false, isSpelledOut: true)
                row(listsEachResult: false, isSpelledOut: false)
            }
            .padding(.horizontal, StatusBarChrome.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: StatusBarChrome.height)
            .paneBarBackground()
            Divider()
        }
    }

    private func row(listsEachResult: Bool, isSpelledOut: Bool) -> some View {
        HStack(spacing: StatusBarChrome.clusterSpacing) {
            // SwiftUI sets a hosted control's size from its environment, so it is set here and not in the control.
            QueryRunTabs(
                strip: QueryRunTabStrip(page: page, results: results, listsEachResult: listsEachResult),
                results: results,
                onChoose: choose
            )
            .controlSize(.small)
            Spacer(minLength: 0)
            if showsMenu, !results.isEmpty {
                ResultSetMenu(model: results, isSpelledOut: isSpelledOut, actions: actions.results)
            }
        }
    }

    private func choose(_ segment: QueryRunTabStrip.Segment) {
        switch segment {
        case .message:
            actions.showPage(.message)
        case .summary:
            actions.showPage(.summary)
        case .result(let entry):
            actions.results.activate(entry.id)
        }
    }
}

struct QueryRunTabs: NSViewRepresentable {
    let strip: QueryRunTabStrip
    let results: ResultSetMenuModel
    let onChoose: (QueryRunTabStrip.Segment) -> Void

    func makeNSView(context: Context) -> QueryRunTabsControl {
        QueryRunTabsControl()
    }

    func updateNSView(_ control: QueryRunTabsControl, context: Context) {
        control.onChoose = onChoose
        control.apply(strip, results: results)
    }

    // Always the width every tab needs, so `ViewThatFits` folds the results rather than squeezing the tabs.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: QueryRunTabsControl, context: Context) -> CGSize? {
        control.intrinsicContentSize
    }
}

// AppKit on purpose, as `ResultSetTabsControl` is: a SwiftUI segmented or `.tabs` picker drops a segment's image,
// and a pinned result's tab shows its pin.
@MainActor
final class QueryRunTabsControl: NSSegmentedControl {
    var onChoose: ((QueryRunTabStrip.Segment) -> Void)?
    private var shownSegments: [QueryRunTabStrip.Segment] = []
    private var litIndex = -1

    init() {
        super.init(frame: .zero)
        trackingMode = .selectOne
        #if SDK_MACOS_27
        if #available(macOS 27.0, *) {
            role = .tabs
        }
        #endif
        target = self
        action = #selector(segmentChosen(_:))
        setAccessibilityLabel(String(localized: "Results"))
        setAccessibilityIdentifier("query-run-tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("QueryRunTabsControl does not support NSCoder init")
    }

    func apply(_ strip: QueryRunTabStrip, results: ResultSetMenuModel) {
        if segmentCount != strip.segments.count {
            segmentCount = strip.segments.count
        }
        for (index, segment) in strip.segments.enumerated() {
            let title = QueryRunTabStrip.title(of: segment, in: results)
            if label(forSegment: index) != title {
                setLabel(title, forSegment: index)
            }
            setImage(Self.isPinned(segment) ? Self.pinImage : nil, forSegment: index)
            setToolTip(QueryRunTabStrip.toolTip(of: segment, in: results), forSegment: index)
        }
        shownSegments = strip.segments
        litIndex = strip.selectedIndex
        selectedSegment = litIndex
    }

    @objc private func segmentChosen(_ sender: NSSegmentedControl) {
        let chosen = selectedSegment
        // The tab's state decides which segment is lit, so a switch the discard prompt cancels leaves it as it was.
        selectedSegment = litIndex
        guard shownSegments.indices.contains(chosen), chosen != litIndex else { return }
        onChoose?(shownSegments[chosen])
    }

    private static func isPinned(_ segment: QueryRunTabStrip.Segment) -> Bool {
        guard case .result(let entry) = segment else { return false }
        return entry.isPinned
    }

    private static let pinImage = NSImage(
        systemSymbolName: "pin.fill",
        accessibilityDescription: String(localized: "Pinned")
    )?.withSymbolConfiguration(NSImage.SymbolConfiguration(scale: .small))
}
