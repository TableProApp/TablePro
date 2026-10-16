//
//  ToolPaneBarThemeTests.swift
//  TableProTests
//
//  A bar or pane fill over the themed detail pane keeps the system fill it drew, and draws nothing
//  while the theme colors the window, so the pane's own color shows through it.
//

import AppKit
import Combine
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

private struct ToolPaneVersionHistoryProvider: VersionHistoryProvider {
    let notice: VersionHistoryNotice?

    func loadHistory() async throws -> VersionHistoryPage {
        VersionHistoryPage(entries: [VersionHistoryEntry(reference: .current)], notice: notice)
    }

    func content(of reference: VersionHistoryReference) async throws -> String {
        ""
    }

    func prepareRestore(_ reference: VersionHistoryReference) async throws -> VersionRestorePlan {
        throw VersionHistoryError.versionNotFound
    }
}

@MainActor
struct ToolPaneBarThemeTests {
    private static let size = CGSize(width: 480, height: 240)

    private func color(of view: some View, at point: CGPoint) throws -> NSColor {
        try ThemeTestFixture.color(
            of: view.frame(width: Self.size.width, height: Self.size.height),
            at: point,
            colorScheme: .dark
        )
    }

    private func expectDropsFill(_ view: some View, at point: CGPoint, native: some ShapeStyle) throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let expected = try ThemeTestFixture.filled(native, colorScheme: .dark)
            let unthemed = try color(of: view, at: point)
            #expect(ThemeTestFixture.matches(unthemed, expected), "the default pair drew \(unthemed), native \(expected)")

            try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
            let themed = try color(of: view, at: point)
            #expect(themed.alphaComponent < 0.05, "the bar drew \(themed) over a themed window")

            try ThemeTestFixture.adopt([
                .editorBackground: ThemeTestFixture.editorHex,
                .gridBackground: ThemeTestFixture.gridHex,
            ], appearance: .dark)
            let unrelated = try color(of: view, at: point)
            #expect(ThemeTestFixture.matches(unrelated, expected), "another slot drew \(unrelated)")
        }
    }

    private func versionHistory(notice: VersionHistoryNotice? = nil) async -> VersionHistoryViewModel {
        let viewModel = VersionHistoryViewModel(
            subject: .savedQuery(id: UUID()),
            provider: ToolPaneVersionHistoryProvider(notice: notice),
            refreshSignal: Empty().eraseToAnyPublisher()
        )
        await viewModel.loadList()
        return viewModel
    }

    @Test("The query plan bar keeps its control background until the theme colors the window")
    func queryPlanBar() throws {
        let view = QueryPlanResultView(
            rawText: "not a plan",
            executionTime: nil,
            plan: nil,
            tabState: QueryPlanTabState(),
            planState: QueryPlanViewState()
        )
        try expectDropsFill(view, at: CGPoint(x: 0.004, y: 0.008), native: Color(nsColor: .controlBackgroundColor))
    }

    @Test("The unparsed plan banner keeps its control background until the theme colors the window")
    func queryPlanBanner() throws {
        let view = QueryPlanResultView(
            rawText: "not a plan",
            executionTime: nil,
            plan: nil,
            tabState: QueryPlanTabState(),
            planState: QueryPlanViewState()
        )
        let banner = try bannerPoint(in: view)
        try expectDropsFill(view, at: banner, native: Color(nsColor: .controlBackgroundColor))
    }

    /// The banner sits under the bar and a divider; the first row below them that the default pair
    /// fills with the control background is inside it.
    private func bannerPoint(in view: QueryPlanResultView) throws -> CGPoint {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let control = try ThemeTestFixture.filled(Color(nsColor: .controlBackgroundColor), colorScheme: .dark)
            let rep = try ThemeTestFixture.bitmap(
                of: view.frame(width: Self.size.width, height: Self.size.height),
                colorScheme: .dark
            )
            // Runs down the leading edge: the bar's fill, the divider, then the banner's fill.
            var runs = 0
            var wasControl = false
            for y in 0 ..< rep.pixelsHigh {
                guard let pixel = ThemeTestFixture.pixel(rep, x: 2, y: y) else { continue }
                let isControl = ThemeTestFixture.matches(pixel, control)
                if isControl, !wasControl {
                    runs += 1
                    if runs == 2 {
                        return CGPoint(x: 2.5 / CGFloat(rep.pixelsWide), y: (CGFloat(y) + 4.5) / CGFloat(rep.pixelsHigh))
                    }
                }
                wasControl = isControl
            }
            Issue.record("no banner under the plan bar")
            return CGPoint(x: 0.004, y: 0.2)
        }
    }

    @Test("The version history header keeps its control background until the theme colors the window")
    func versionHistoryHeader() async throws {
        let view = VersionHistoryDetailHeader(viewModel: await versionHistory())
        // The header keeps its own height, centred in the frame.
        try expectDropsFill(view, at: CGPoint(x: 0.004, y: 0.5), native: Color(nsColor: .controlBackgroundColor))
    }

    @Test("The version history notice keeps its control background until the theme colors the window")
    func versionHistoryNotice() async throws {
        let viewModel = await versionHistory(notice: .keepsLatestVersions(50))
        #expect(viewModel.page.notice != nil)
        let view = VersionHistoryListPane(viewModel: viewModel)
        try expectDropsFill(view, at: CGPoint(x: 0.004, y: 0.99), native: Color(nsColor: .controlBackgroundColor))
    }

    @Test("The Query Insights toolbar keeps its material until the theme colors the window")
    func queryInsightsToolbar() throws {
        let viewModel = QueryInsightsViewModel(connectionId: UUID(), history: QueryHistoryManager.shared)
        try expectDropsFill(QueryInsightsToolbar(viewModel: viewModel), at: CGPoint(x: 0.004, y: 0.5), native: .bar)
    }
}

/// The scope pane sits in an AppKit split view, which only a real hosting view draws.
@MainActor
struct PrivilegeScopePaneThemeTests {
    private static let size = NSSize(width: 720, height: 360)

    private func snapshot(_ view: some View) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: Self.size.width, height: Self.size.height))
        host.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func corner(of view: some View) throws -> NSColor {
        let rep = try snapshot(view)
        return try #require(ThemeTestFixture.pixel(rep, x: 3, y: 3))
    }

    @Test("The privilege scope pane keeps its control background until the theme colors the window")
    func scopePane() throws {
        let viewModel = UsersRolesViewModel(connectionId: UUID(), databaseType: .postgresql)
        let pane = PrivilegeEditorPane(viewModel: viewModel)
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let native = try corner(of: Color(nsColor: .controlBackgroundColor))
            let unthemed = try corner(of: pane)
            #expect(ThemeTestFixture.matches(unthemed, native), "the default pair drew \(unthemed), native \(native)")

            try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
            let themed = try corner(of: pane)
            #expect(themed.alphaComponent < 0.05, "the pane drew \(themed) over a themed window")
        }
    }
}
