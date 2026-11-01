import AppKit
import Foundation
import SwiftUI
import Testing

@testable import TablePro

private let tabBarHostWidths: [CGFloat] = [1_400, 900, 600, 400, 320]

@MainActor
struct ResultSetTabBarLayoutTests {
    @Test("Tabs show when every name fits the pane")
    func tabsShowWhenTheyFit() {
        let host = host(ResultSetTabBar(model: Self.model(labels: ["users", "orders", "Result 3"]), actions: .none), width: 900)

        #expect(tabControls(in: host).count == 1)
        #expect(tabControls(in: host).first?.segmentCount == 3)
    }

    @Test("A pane too narrow for the tabs keeps only the pull-down")
    func narrowPaneFallsBackToThePullDown() {
        let labels = (1 ... 6).map { "monthly_revenue_by_region_\($0)" }
        let host = host(ResultSetTabBar(model: Self.model(labels: labels), actions: .none), width: 400)

        #expect(tabControls(in: host).isEmpty)
    }

    @Test("More than six results are listed by the pull-down alone")
    func moreThanSixHaveNoTabs() {
        let labels = (1 ... 7).map { "r\($0)" }
        let host = host(ResultSetTabBar(model: Self.model(labels: labels), actions: .none), width: 1_400)

        #expect(tabControls(in: host).isEmpty)
    }

    @Test("A pinned result's tab carries the pin and selection follows the active result")
    func tabsMirrorTheModel() throws {
        let host = host(
            ResultSetTabBar(model: Self.model(labels: ["users", "orders"], activeIndex: 1, pinnedIndices: [0]), actions: .none),
            width: 900
        )
        let tabs = try #require(tabControls(in: host).first)

        #expect(tabs.image(forSegment: 0) != nil)
        #expect(tabs.image(forSegment: 1) == nil)
        #expect(tabs.selectedSegment == 1)
        #expect(tabs.label(forSegment: 0) == "users")
    }

    @Test("The tabs never reach past the pane", arguments: tabBarHostWidths)
    func tabsStayInsideThePane(width: CGFloat) {
        let labels = ["users", "orders", "invoice_line_items", "Result 4"]
        let host = host(ResultSetTabBar(model: Self.model(labels: labels), actions: .none), width: width)

        for tabs in tabControls(in: host) {
            let frame = tabs.convert(tabs.bounds, to: host.view)
            #expect(frame.minX >= 0 && frame.maxX <= width, "tabs at \(frame) in a \(width)pt pane")
        }
    }

    // The results pane can be dragged down to 150pt; with a long error the banner gives way, never the bars.
    @Test("At the pane's minimum height the tab row and the status bar both stay inside it")
    func shortPaneKeepsBothBars() throws {
        let box = BarFrames()
        let message = Array(repeating: "ERROR: relation \"nope\" does not exist at character 15", count: 8)
            .joined(separator: "\n")
        let stack = VStack(spacing: 0) {
            ResultSetTabBar(model: Self.model(labels: ["Result 1", "Error"]), actions: .none)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.pane)) } action: { box.top = $0 }
            InlineErrorBanner(message: message)
            Color.clear.frame(maxHeight: .infinity)
            Color.clear
                .frame(height: StatusBarChrome.height + 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.pane)) } action: { box.bottom = $0 }
        }
        let height = CollapsibleSplitController.defaultBottomMinimumThickness
        // An oversized stack is centred in its frame, so an overflow shows as a bar outside the pane's bounds.
        let pane = stack
            .frame(width: 600, height: height)
            .coordinateSpace(name: Self.pane)
        _ = host(pane, width: 600, height: height)

        let top = try #require(box.top)
        let bottom = try #require(box.bottom)
        #expect(top.minY >= 0, "the tab row starts at \(top.minY)")
        #expect(bottom.maxY <= height, "the status bar ends at \(bottom.maxY) in a \(height)pt pane")
    }

    private static let pane = "pane"

    private func host(_ content: some View, width: CGFloat, height: CGFloat = 40) -> HostedView {
        let host = NSHostingView(rootView: AnyView(content))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return HostedView(view: host, window: window)
    }

    private func tabControls(in hosted: HostedView) -> [ResultSetTabsControl] {
        tabControls(in: hosted.view)
    }

    private func tabControls(in view: NSView) -> [ResultSetTabsControl] {
        let own = (view as? ResultSetTabsControl).map { [$0] } ?? []
        return own + view.subviews.flatMap { tabControls(in: $0) }.filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    private static func model(labels: [String], activeIndex: Int = 0, pinnedIndices: Set<Int> = []) -> ResultSetMenuModel {
        let entries = labels.enumerated().map { index, label in
            ResultSetMenuEntry(
                id: UUID(),
                label: label,
                isPinned: pinnedIndices.contains(index),
                isActive: index == activeIndex,
                ordinal: index + 1,
                isComparable: true
            )
        }
        return ResultSetMenuModel(entries: entries, activeOrdinal: activeIndex + 1, total: labels.count)
    }
}

private struct HostedView {
    let view: NSView
    let window: NSWindow
}

@MainActor
private final class BarFrames {
    var top: CGRect?
    var bottom: CGRect?
}
