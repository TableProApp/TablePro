//
//  ValueViewerWindowMinimumSizeTests.swift
//  TableProTests
//
//  A hosting view that is a window's content view rewrites the window's size limits from its
//  SwiftUI content. Every viewer set a minimum on the window and lost it on the first constraint
//  pass: the geometry map window measured 58 by 72, the text viewer 0 by 32.
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct ValueViewerWindowMinimumSizeTests {
    /// The shape of the text viewer: one editor that takes whatever it is given.
    private struct FlexibleContent: View {
        var body: some View {
            Color.clear
        }
    }

    /// The shape of the JSON, PHP, image and geometry viewers: a short toolbar over flexible content.
    private struct ToolbarContent: View {
        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Fit") {}
                }
                .padding(6)
                Divider()
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The pass the hosting view rewrites the limits in. It runs by itself one turn after the
    /// window is built, so it is run here to judge the window as a user finds it.
    private func settledWindow<Content: View>(_ content: Content) -> NSWindow {
        let window = ValueViewerWindowController.makeWindow(identifier: "test-viewer", title: "Test") { _ in
            content
        }
        window.updateConstraintsIfNeeded()
        return window
    }

    @Test("A viewer whose content has no minimum keeps the window minimum")
    func flexibleContentKeepsTheMinimum() {
        let window = settledWindow(FlexibleContent())
        #expect(window.minSize == ValueViewerWindowController.minSize)
    }

    @Test("A viewer with a small toolbar keeps the window minimum")
    func toolbarContentKeepsTheMinimum() {
        let window = settledWindow(ToolbarContent())
        #expect(window.minSize == ValueViewerWindowController.minSize)
    }

    @Test("The window minimum is 400 by 300")
    func minimumIsUnchanged() {
        #expect(ValueViewerWindowController.minSize == NSSize(width: 400, height: 300))
    }

    /// The floor is a minimum only: a viewer still opens at its default size and still grows.
    @Test("The floor leaves the window resizable above it")
    func windowStaysResizable() {
        let window = settledWindow(ToolbarContent())
        #expect(window.frame.width > ValueViewerWindowController.minSize.width)
        #expect(window.maxSize.width > 10_000)
        #expect(window.maxSize.height > 10_000)
        #expect(window.styleMask.contains(.resizable))
    }

    /// One shared path builds every viewer's window, so the floor reaches all of them.
    @Test("Every viewer builds its window through the shared controller")
    func everyViewerUsesTheSharedPath() throws {
        let viewers = [
            "CellImageWindowController",
            "GeometryMapWindowController",
            "JSONViewerWindowController",
            "PhpViewerWindowController",
            "TextViewerWindowController"
        ]
        let root = try repositoryRoot()
        for viewer in viewers {
            let path = "TablePro/Views/Results/\(viewer).swift"
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains(": ValueViewerWindowController"), "\(viewer) left the shared controller")
            #expect(source.contains("controller.present("), "\(viewer) no longer presents through it")
            #expect(!source.contains("NSWindow("), "\(viewer) builds a window of its own")
        }
    }

    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
