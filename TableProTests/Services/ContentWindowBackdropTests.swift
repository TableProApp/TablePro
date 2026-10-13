//
//  ContentWindowBackdropTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// The real controllers, built offscreen: never ordered front and never closed.
@Suite("Content windows carry the theme's window backdrop", .serialized)
@MainActor
struct ContentWindowBackdropTests {
    private var drawsBackdrop: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private func hex(of window: NSWindow) -> String {
        var hex = ""
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            hex = HexColor.string(from: window.backgroundColor)
        }
        return hex
    }

    /// The controller must hold the backdrop: a theme switched after it was built still has to reach the window.
    private func expectFollowsTheTheme(_ window: NSWindow) throws {
        window.appearance = NSAppearance(named: .darkAqua)
        let original = window.backgroundColor
        #expect(original == NSColor.windowBackgroundColor, "the default pair touched the window")

        try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
        if drawsBackdrop {
            #expect(hex(of: window) == ThemeTestFixture.windowHex)
        } else {
            #expect(window.backgroundColor === original)
        }

        try ThemeTestFixture.adopt([.editorBackground: ThemeTestFixture.editorHex], appearance: .dark)
        #expect(window.backgroundColor === original, "a content color reached the window")

        ThemeTestFixture.adopt(.builtIn, appearance: .dark)
        #expect(window.backgroundColor === original)
    }

    @Test("The main window takes a theme's window color and hands its own back")
    func mainWindowFollowsTheTheme() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_200, height: 800))
            defer { fixture.tearDown() }
            try expectFollowsTheTheme(fixture.window)
        }
    }

    @Test("A data file window takes a theme's window color and hands its own back")
    func dataFileWindowFollowsTheTheme() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let controller = DataFileWindowController(document: DataFileDocument())
            let window = try #require(controller.window)
            defer { window.delegate = nil }
            try expectFollowsTheTheme(window)
        }
    }

    private static let contentWindowControllers = [
        "TablePro/Core/Services/Infrastructure/TabWindowController.swift",
        "TablePro/Views/DataFiles/DataFileWindowController.swift",
        "TablePro/Views/Compare/CompareSyncWindowController.swift",
        "TablePro/Views/Results/ValueViewerWindowController.swift",
    ]

    private static let systemWindowControllers = [
        "TablePro/Views/Settings/SettingsWindowController.swift",
        "TablePro/Views/Welcome/WelcomeWindowController.swift",
        "TablePro/Views/ConnectionForm/ConnectionFormWindowController.swift",
    ]

    private func code(of path: String) throws -> String {
        let url = try ThemeSourceScan.repositoryRoot().appendingPathComponent(path)
        let source = try String(contentsOf: url, encoding: .utf8)
        return ThemeSourceScan.codeLines(of: source, path: path).map(\.text).joined(separator: "\n")
    }

    /// A backdrop held only by a local stops answering theme changes as soon as `init` returns.
    @Test("Each content window controller stores the backdrop it attaches")
    func contentWindowsStoreTheirBackdrop() throws {
        let stored = try ThemeSourceScan.Rule("stored backdrop", #"(let|var)\s+\w+\s*:\s*ThemeWindowBackdrop\b"#)
        let attached = try ThemeSourceScan.Rule("attached backdrop", #"\w+\s*=\s*ThemeWindowBackdrop\(window:"#)
        for path in Self.contentWindowControllers {
            let code = try code(of: path)
            #expect(stored.matches(code), "\(path) does not store a ThemeWindowBackdrop")
            #expect(attached.matches(code), "\(path) does not attach a ThemeWindowBackdrop")
        }
    }

    @Test("Settings, Welcome and the connection form keep the system window")
    func systemWindowsHaveNoBackdrop() throws {
        for path in Self.systemWindowControllers {
            let code = try code(of: path)
            #expect(!code.contains("ThemeWindowBackdrop"), "\(path) attaches a window backdrop")
        }
    }
}
