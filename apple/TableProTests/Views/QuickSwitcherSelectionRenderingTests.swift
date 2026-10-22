//
//  QuickSwitcherSelectionRenderingTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTestSupport
import Testing

/// Reads the drawn Open Quickly list: the scroll view SwiftUI backs its `ScrollView` with, and the
/// selection fill under the panel's glass. Both are private rendering, so the cases run only where
/// the probe sees one fill for one selected row. `QuickSwitcherViewModelTests` covers the model.
@MainActor
struct QuickSwitcherSelectionRenderingTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    static func hostDrawsTheSelection() async -> Bool {
        guard let suite = try? EphemeralDefaults() else { return false }
        let viewModel = await makeViewModel(tables: ["alpha", "beta", "gamma"], defaults: suite.defaults)
        let panel = DrawnPanel(viewModel: viewModel)
        return (try? await waitUntil(timeout: .seconds(5)) { panel.read()?.bands.count == 1 }) != nil
    }

    private static func makeViewModel(tables: [String], defaults: UserDefaults) async -> QuickSwitcherViewModel {
        let viewModel = QuickSwitcherViewModel(connectionId: UUID(), services: .live, defaults: defaults)
        viewModel.allItems = tables.map { name in
            QuickSwitcherItem(frecencyKey: "table:\(name)", name: name, kind: .table, subtitle: "")
        }
        viewModel.scope = .tables
        await viewModel.flushPendingFilter()
        return viewModel
    }

    private func resultTop(_ index: Int) -> CGFloat {
        QuickSwitcherMetrics.listVerticalPadding + CGFloat(index) * QuickSwitcherMetrics.rowHeight
    }

    @Test(
        "A query that moves rows out of their section draws the highlight on the selected row (#3785)",
        .enabled("The host draws no selection fill in the panel") { await Self.hostDrawsTheSelection() }
    )
    func highlightFollowsSelectionAfterQuery() async throws {
        let viewModel = await Self.makeViewModel(
            tables: ["Album", "Artist", "Customer", "Employee", "Genre", "Invoice", "InvoiceLine", "MediaType", "Track"],
            defaults: suite.defaults
        )
        let panel = DrawnPanel(viewModel: viewModel)
        try await waitUntil(timeout: .seconds(5)) { panel.read()?.bands.count == 1 }

        viewModel.searchText = "e"
        await viewModel.flushPendingFilter()
        try #require(viewModel.flatItems.count > 3)

        for index in 0 ..< 3 {
            if index > 0 { viewModel.moveSelection(by: 1) }
            #expect(viewModel.selectedItemId == viewModel.flatItems[index].id)
            let top = resultTop(index)
            try await waitUntil(timeout: .seconds(3)) {
                guard let bands = panel.read()?.bands, bands.count == 1 else { return false }
                return abs(bands[0].lowerBound - top) <= 1
            }
        }
    }

    @Test(
        "A new query whose best match is the scrolled-away selection scrolls back to it",
        .enabled("The host draws no selection fill in the panel") { await Self.hostDrawsTheSelection() }
    )
    func newQueryKeepingTheSelectionRevealsIt() async throws {
        let viewModel = await Self.makeViewModel(
            tables: (0 ..< 40).map { String(format: "book_%02d", $0) } + ["orders"],
            defaults: suite.defaults
        )
        let panel = DrawnPanel(viewModel: viewModel)
        try await waitUntil(timeout: .seconds(5)) { panel.read()?.bands.count == 1 }
        viewModel.moveSelection(by: 40)
        try #require(viewModel.selectedItem()?.name == "orders")
        try await waitUntil(timeout: .seconds(3)) { (panel.read()?.offset ?? 0) > 1_000 }

        viewModel.searchText = "o"
        await viewModel.flushPendingFilter()
        try #require(viewModel.flatItems.first?.name == "orders")
        try #require(viewModel.flatItems.count > QuickSwitcherMetrics.maxVisibleRows)

        let top = resultTop(0)
        try await waitUntil(timeout: .seconds(3)) {
            guard let bands = panel.read()?.bands, bands.count == 1 else { return false }
            return abs(bands[0].lowerBound - top) <= 1
        }
    }

    @Test(
        "Arrowing back to a section's first row shows the section header again",
        .enabled("The host draws no selection fill in the panel") { await Self.hostDrawsTheSelection() }
    )
    func arrowingUpRevealsTheSectionHeader() async throws {
        let viewModel = await Self.makeViewModel(
            tables: (0 ..< 30).map { String(format: "table_%02d", $0) },
            defaults: suite.defaults
        )
        let panel = DrawnPanel(viewModel: viewModel)
        try await waitUntil(timeout: .seconds(5)) { panel.read()?.bands.count == 1 }

        viewModel.moveSelection(by: 20)
        try await waitUntil(timeout: .seconds(3)) { (panel.read()?.offset ?? 0) > 400 }
        viewModel.moveSelection(by: -20)

        try await waitUntil(timeout: .seconds(3)) {
            guard let offset = panel.read()?.offset else { return false }
            return offset <= QuickSwitcherMetrics.listVerticalPadding + 1
        }
    }
}

/// The real panel content in a window, read back as the selection bands its list draws.
@MainActor
private final class DrawnPanel {
    struct Reading {
        /// Each run of selection fill, as a span of the list's document in points.
        let bands: [ClosedRange<CGFloat>]
        let offset: CGFloat
    }

    private let window: NSWindow
    private let selectionFill: NSColor?

    init(viewModel: QuickSwitcherViewModel) {
        window = ThemeTestFixture.host(
            QuickSwitcherPanelContent(viewModel: viewModel) { _, _ in },
            size: NSSize(width: QuickSwitcherMetrics.width, height: 640)
        )
        selectionFill = Self.hostedFill()
    }

    /// Taken through the same window and snapshot path, so color management cancels out.
    private static func hostedFill() -> NSColor? {
        let size = NSSize(width: 40, height: 40)
        let window = ThemeTestFixture.host(Color(nsColor: .selectedContentBackgroundColor), size: size)
        guard let bitmap = ThemeTestFixture.snapshot(window) else { return nil }
        return ThemeTestFixture.pixel(bitmap, x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
    }

    func read() -> Reading? {
        guard let selectionFill, let root = window.contentView else { return nil }
        root.layoutSubtreeIfNeeded()
        guard let scrollView = Self.listScrollView(in: root),
              let documentView = scrollView.documentView,
              let bitmap = ThemeTestFixture.snapshot(window) else { return nil }

        let scale = CGFloat(bitmap.pixelsHigh) / root.bounds.height
        let visible = scrollView.convert(scrollView.bounds, to: root)
        let top = root.isFlipped ? visible.minY : root.bounds.height - visible.maxY
        let clip = scrollView.contentView.bounds
        let offset = documentView.isFlipped ? clip.minY : documentView.bounds.height - clip.maxY
        let column = Int((visible.minX + visible.width * 0.6) * scale)

        var bands: [ClosedRange<CGFloat>] = []
        var start: CGFloat?
        let firstRow = Int((top * scale).rounded(.up))
        let lastRow = Int(((top + visible.height) * scale).rounded(.down))
        for pixelRow in firstRow ... lastRow {
            let documentY = CGFloat(pixelRow) / scale - top + offset
            let isFill = pixelRow < lastRow
                && ThemeTestFixture.pixel(bitmap, x: column, y: pixelRow)
                    .map { ThemeTestFixture.matches($0, selectionFill, tolerance: 0.03) } == true
            if isFill, start == nil {
                start = documentY
            } else if !isFill, let bandStart = start {
                bands.append(bandStart ... documentY)
                start = nil
            }
        }
        return Reading(bands: bands, offset: offset)
    }

    private static func listScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, !(scrollView.documentView is NSTextView) {
            return scrollView
        }
        return view.subviews.lazy.compactMap { listScrollView(in: $0) }.first
    }
}
