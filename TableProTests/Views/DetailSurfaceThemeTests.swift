//
//  DetailSurfaceThemeTests.swift
//  TableProTests
//
//  Each surface keeps the system color it drew before themes reached it, and takes the theme
//  color only for the slot it stands for.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@Suite("Detail surfaces keep their system color until the theme sets their slot", .serialized)
@MainActor
struct DetailSurfaceThemeTests {
    private static let size = CGSize(width: 320, height: 240)

    private static let slotColors: [ThemeSlot: String] = [
        .windowBackdrop: ThemeSurfaceProbe.windowHex,
        .editorBackground: ThemeSurfaceProbe.editorHex,
        .gridBackground: ThemeSurfaceProbe.gridHex,
    ]

    /// Under the default pair the surface draws `native`; under its own slot it draws the theme; under every other slot it still draws `native`.
    private func assertSurface(_ view: some View, at point: CGPoint, slot: ThemeSlot, native: NSColor) throws {
        let hex = try #require(Self.slotColors[slot])
        let others = Self.slotColors.filter { $0.key != slot }

        try ThemeSurfaceProbe.adopting(dark: BuiltInThemes.dark) {
            let expected = try ThemeSurfaceProbe.filled(native)
            let drawn = try ThemeSurfaceProbe.color(of: view, at: point)
            #expect(ThemeSurfaceProbe.matches(drawn, expected), "default pair drew \(drawn), native \(expected)")

            ThemeSurfaceProbe.adopt(dark: try ThemeSurfaceProbe.darkTheme([slot: hex]))
            let themed = try ThemeSurfaceProbe.color(of: view, at: point)
            let theme = try ThemeSurfaceProbe.filled(hex: hex)
            #expect(ThemeSurfaceProbe.matches(themed, theme), "\(slot.rawValue) drew \(themed), theme \(theme)")

            ThemeSurfaceProbe.adopt(dark: try ThemeSurfaceProbe.darkTheme(others))
            let unrelated = try ThemeSurfaceProbe.color(of: view, at: point)
            #expect(ThemeSurfaceProbe.matches(unrelated, expected), "another slot drew \(unrelated), native \(expected)")
        }
    }

    @Test("Version history fills the window backdrop, over its own text background")
    func versionHistoryRoot() throws {
        let view = VersionHistoryTabView(
            tabId: UUID(),
            subject: .savedQuery(id: UUID()),
            databaseType: .mysql,
            exportFileName: "query.sql",
            onOpenInEditor: { _ in }
        )
        .frame(width: Self.size.width, height: Self.size.height)
        try assertSurface(view, at: CGPoint(x: 0.03, y: 0.05), slot: .windowBackdrop, native: .textBackgroundColor)
    }

    @Test("An object source that is still loading sits on the editor background")
    func objectSourceLoading() throws {
        let view = ObjectSourceTabView(
            connectionId: UUID(),
            databaseType: .mysql,
            objectRef: DatabaseObjectRef(kind: .view, name: "active_orders", database: "shop"),
            onOpenInEditor: { _ in }
        )
        .frame(width: Self.size.width, height: Self.size.height)
        try assertSurface(view, at: CGPoint(x: 0.03, y: 0.95), slot: .editorBackground, native: .textBackgroundColor)
    }

    @Test("A data file window's content fills the window backdrop")
    func dataFileRoot() throws {
        let controller = DataFileController()
        let view = DataFileContentView(controller: controller, gridDelegate: DataFileGridDelegate(controller: controller))
            .frame(width: Self.size.width, height: Self.size.height)
        try assertSurface(view, at: CGPoint(x: 0.03, y: 0.05), slot: .windowBackdrop, native: .windowBackgroundColor)
    }

    @Test("A data file with no rows covers the grid in the grid's own background")
    func dataFileEmptyRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetailSurfaceThemeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("empty.csv")
        try Data("name,age\n".utf8).write(to: url)

        let controller = DataFileController()
        controller.load(url: url, kind: try #require(DataFileKind.classify(url)))
        await controller.waitForPendingWork()
        #expect(controller.loadState == .loaded)
        #expect(controller.tableRows.rows.isEmpty)

        let view = DataFileContentView(controller: controller, gridDelegate: DataFileGridDelegate(controller: controller))
            .frame(width: Self.size.width, height: Self.size.height)
        try assertSurface(view, at: CGPoint(x: 0.03, y: 0.05), slot: .gridBackground, native: .textBackgroundColor)
    }

    @Test("The filter panel header keeps its control background until the theme colors the window")
    func filterPanelHeader() throws {
        let view = FilterPanelView(
            state: .constant(TabFilterState()),
            configuration: FilterPanelConfiguration(
                columns: [],
                primaryKeyColumn: nil,
                offersRawFilter: false,
                caseMatching: .inMemory,
                sqlPreview: nil,
                presetStore: nil
            ),
            actions: DataFileController()
        )
        .frame(width: 480)
        try assertSurface(view, at: CGPoint(x: 0.004, y: 0.1), slot: .windowBackdrop, native: .controlBackgroundColor)
    }
}
