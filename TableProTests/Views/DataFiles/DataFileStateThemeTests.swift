//
//  DataFileStateThemeTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

/// The Data File window's content sits on the window backdrop, and its loading and failure states
/// stand in for the grid, so they take the grid's background while a theme sets it.
@MainActor
struct DataFileStateThemeTests {
    private static let size = CGSize(width: 320, height: 240)
    private static let body = CGPoint(x: 0.03, y: 0.05)

    private func content(_ controller: DataFileController) -> some View {
        DataFileContentView(controller: controller, gridDelegate: DataFileGridDelegate(controller: controller))
            .frame(width: Self.size.width, height: Self.size.height)
    }

    private func failedController() async throws -> DataFileController {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataFileStateThemeTests-\(UUID().uuidString)")
            .appendingPathComponent("missing.csv")
        let controller = DataFileController()
        controller.load(url: missing, kind: try #require(DataFileKind.classify(missing)))
        await controller.waitForPendingWork()
        guard case .failed = controller.loadState else {
            Issue.record("The missing file loaded as \(controller.loadState)")
            return controller
        }
        return controller
    }

    private func drawn(_ view: some View) throws -> NSColor {
        try ThemeTestFixture.color(of: view, at: Self.body, colorScheme: .dark)
    }

    @Test("The content fills the window backdrop, and only the window slot themes it")
    func rootFollowsTheWindowSlot() throws {
        let view = content(DataFileController())
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let native = try ThemeTestFixture.filled(NSColor.windowBackgroundColor, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(try drawn(view), native))

            try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
            let window = try ThemeTestFixture.filled(hex: ThemeTestFixture.windowHex, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(try drawn(view), window))

            try ThemeTestFixture.adopt([.editorBackground: ThemeTestFixture.editorHex], appearance: .dark)
            #expect(ThemeTestFixture.matches(try drawn(view), native))
        }
    }

    @Test("Opening a file stands in for the grid in the grid's background")
    func loadingTakesTheGridBackground() throws {
        let view = content(DataFileController())
        try ThemeTestFixture.adopting([.gridBackground: ThemeTestFixture.gridHex], appearance: .dark) {
            let grid = try ThemeTestFixture.filled(hex: ThemeTestFixture.gridHex, colorScheme: .dark)
            let loading = try drawn(view)
            #expect(ThemeTestFixture.matches(loading, grid), "loading drew \(loading), grid \(grid)")
        }
    }

    @Test("A file that cannot be opened stands in for the grid in the grid's background")
    func failureTakesTheGridBackground() async throws {
        let controller = try await failedController()
        let view = content(controller)
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let native = try ThemeTestFixture.filled(NSColor.windowBackgroundColor, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(try drawn(view), native), "the default pair moved the failure state")

            try ThemeTestFixture.adopt([.gridBackground: ThemeTestFixture.gridHex], appearance: .dark)
            let grid = try ThemeTestFixture.filled(hex: ThemeTestFixture.gridHex, colorScheme: .dark)
            let failure = try drawn(view)
            #expect(ThemeTestFixture.matches(failure, grid), "failure drew \(failure), grid \(grid)")
        }
    }
}
