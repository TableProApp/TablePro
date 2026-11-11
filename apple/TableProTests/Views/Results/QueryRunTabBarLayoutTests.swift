import AppKit
import Foundation
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct QueryRunTabBarLayoutTests {
    @Test("A wide pane shows Message, Summary and a tab per result, with the result lit")
    func wideRowListsEachResult() throws {
        let bar = QueryRunTabBar(page: .result, results: Self.model(labels: ["users", "orders"], activeIndex: 1), actions: .none)
        let hosted = host(bar, width: 900)
        let tabs = try #require(tabControls(in: hosted.view).first)

        #expect(tabs.segmentCount == 4)
        #expect(tabs.label(forSegment: 0) == "Message")
        #expect(tabs.label(forSegment: 1) == "Summary")
        #expect(tabs.label(forSegment: 3) == "orders")
        #expect(tabs.selectedSegment == 3)
    }

    @Test("One result still gets its own tab beside Message and Summary")
    func oneResultHasATab() throws {
        let hosted = host(QueryRunTabBar(page: .message, results: Self.model(labels: ["users"]), actions: .none), width: 900)
        let tabs = try #require(tabControls(in: hosted.view).first)

        #expect(tabs.segmentCount == 3)
        #expect(tabs.selectedSegment == 0)
    }

    @Test("A narrow pane folds the results into one tab rather than cutting the row off")
    func narrowPaneFolds() throws {
        let labels = (1 ... 6).map { "monthly_revenue_by_region_\($0)" }
        let hosted = host(QueryRunTabBar(page: .summary, results: Self.model(labels: labels), actions: .none), width: 420)
        let tabs = try #require(tabControls(in: hosted.view).first)

        #expect(tabs.segmentCount == 3)
        #expect(tabs.selectedSegment == 1)
    }

    @Test("Choosing a tab asks for its page or its result, and leaves the lit tab to the model")
    func choosingReportsTheSegment() throws {
        let model = Self.model(labels: ["users", "orders"])
        let recorder = ChoiceRecorder()
        let actions = QueryRunTabActions(
            showPage: { recorder.pages.append($0) },
            results: ResultSetActions(
                activate: { recorder.results.append($0) },
                togglePin: { _ in }, compare: { _ in }, close: { _ in }, closeOthers: { _ in }
            )
        )
        let hosted = host(QueryRunTabBar(page: .result, results: model, actions: actions), width: 900)
        let tabs = try #require(tabControls(in: hosted.view).first)

        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        tabs.selectedSegment = 3
        tabs.sendAction(tabs.action, to: tabs.target)

        #expect(recorder.pages == [.summary])
        #expect(recorder.results == [model.entries[1].id])
        #expect(tabs.selectedSegment == 2)
    }

    private func host(_ content: some View, width: CGFloat) -> HostedRow {
        let host = NSHostingView(rootView: AnyView(content))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 40)
        host.layoutSubtreeIfNeeded()
        return HostedRow(view: host, window: window)
    }

    private func tabControls(in view: NSView) -> [QueryRunTabsControl] {
        let own = (view as? QueryRunTabsControl).map { [$0] } ?? []
        return own + view.subviews.flatMap { tabControls(in: $0) }.filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    private static func model(labels: [String], activeIndex: Int = 0) -> ResultSetMenuModel {
        let entries = labels.enumerated().map { index, label in
            ResultSetMenuEntry(
                id: UUID(),
                label: label,
                isPinned: false,
                isActive: index == activeIndex,
                ordinal: index + 1,
                isComparable: true
            )
        }
        return ResultSetMenuModel(entries: entries, activeOrdinal: activeIndex + 1, total: labels.count)
    }
}

private struct HostedRow {
    let view: NSView
    let window: NSWindow
}

@MainActor
private final class ChoiceRecorder {
    var pages: [ResultsPage] = []
    var results: [UUID] = []
}
