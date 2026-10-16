//
//  CommandPreviewThemeTests.swift
//  TableProTests
//
//  The deep-link sheet's Startup SQL and the tunnel command's Will Run preview are code fields, so
//  each sits in a well that wears the editor theme while the form around it stays system.
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProImport
import TableProTheme
import Testing

@MainActor
struct CommandPreviewThemeTests {
    private static let sheetSize = NSSize(width: 420, height: 560)
    private static let formSize = NSSize(width: 480, height: 720)

    private func bundle(startupCommands: String?) throws -> ConnectionBundle {
        var settings = ExportableConnection(
            name: "Shared",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "reader",
            type: DatabaseType.postgresql.rawValue
        )
        settings.startupCommands = startupCommands
        return try ConnectionBundle(appVersion: "1.0", connections: [BundleConnection(ref: "c1", settings: settings)])
    }

    private func magentaCount(_ view: some View, size: NSSize) throws -> Int {
        let window = ThemeTestFixture.host(view, size: size)
        defer { withExtendedLifetime(window) {} }
        let snapshot = try #require(ThemeTestFixture.snapshot(window))
        return ThemeTestFixture.count(in: snapshot, where: ThemeTestFixture.isMagenta)
    }

    @Test("A shared connection's Startup SQL sits in an editor-themed well")
    func startupSQLWearsTheEditorTheme() throws {
        let withSQL = DeeplinkImportSheet(bundle: try bundle(startupCommands: "SET search_path TO app;"), onFinished: { _ in })
        let withoutSQL = DeeplinkImportSheet(bundle: try bundle(startupCommands: nil), onFinished: { _ in })
        try ThemeTestFixture.adopting(ThemeTestFixture.pair([.editorBackground: "#FF00FF"]), appearance: .light) {
            let themed = try magentaCount(withSQL, size: Self.sheetSize)
            let withoutWell = try magentaCount(withoutSQL, size: Self.sheetSize)
            #expect(themed > 200)
            #expect(withoutWell == 0, "something else in the sheet took the theme")
        }
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let unthemed = try magentaCount(withSQL, size: Self.sheetSize)
            #expect(unthemed == 0)
        }
    }

    @Test("The tunnel command's Will Run preview sits in an editor-themed well")
    func tunnelPreviewWearsTheEditorTheme() throws {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.tunnelCommand.state.config.method = .custom
        coordinator.tunnelCommand.state.config.command = "ssh -N -L {port}:{host}:{remotePort} bastion"
        try #require(coordinator.tunnelCommandPreview != nil)
        let form = Form { TunnelCommandTransportSections(coordinator: coordinator) }.formStyle(.grouped)

        try ThemeTestFixture.adopting(ThemeTestFixture.pair([.editorBackground: "#FF00FF"]), appearance: .light) {
            let themed = try magentaCount(form, size: Self.formSize)
            #expect(themed > 200)
        }
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let unthemed = try magentaCount(form, size: Self.formSize)
            #expect(unthemed == 0)
        }
    }
}
