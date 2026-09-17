//
//  MenuItemImageVisibilityTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// From macOS 27 AppKit hides menu item symbol images by default. Where the image is the only thing
/// telling two rows apart, a connection colour, a folder colour, an engine glyph, a Safe Mode level,
/// a drift warning, the row loses its meaning rather than its decoration.
@Suite("Menu item image visibility")
struct MenuItemImageVisibilityTests {
    @Test("An informative image is set and, on macOS 27, marked visible")
    func informativeImageIsMarkedVisible() {
        let item = NSMenuItem(title: "Red", action: nil, keyEquivalent: "")
        let image = NSImage(size: NSSize(width: 12, height: 12))

        item.setInformativeImage(image)

        #expect(item.image === image)
        if #available(macOS 27.0, *) {
            #expect(item.preferredImageVisibility == .visible)
        }
    }

    @Test("Clearing an informative image leaves no stale image behind")
    func clearingAnInformativeImage() {
        let item = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
        item.setInformativeImage(NSImage(size: NSSize(width: 12, height: 12)))

        item.setInformativeImage(nil)

        #expect(item.image == nil)
    }

    @Test("Every menu whose image carries the meaning goes through the helper")
    func informativeMenuBuildersUseTheHelper() throws {
        let root = try repositoryRoot()
        let sources = [
            "TablePro/Views/Highlight/HighlightMenuBuilder.swift",
            "TablePro/Views/Sidebar/Menu/SidebarMenuBuilder.swift",
            "TablePro/Views/Connection/GroupPopUpButton.swift",
            "TablePro/Core/Menu/SafeModeMenuDelegate.swift",
            "TablePro/Views/Results/EnumMenuPicker.swift",
        ]

        for source in sources {
            let text = try String(contentsOf: root.appendingPathComponent(source), encoding: .utf8)
            #expect(
                text.contains("setInformativeImage("),
                """
                \(source) builds a menu whose image is the row's only distinguishing content, so it \
                must use `setInformativeImage(_:)`. On macOS 27 a plain `image =` is hidden and the \
                rows become identical.
                """
            )
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
        throw MenuImageTestError.repositoryRootNotFound
    }

    private enum MenuImageTestError: Error {
        case repositoryRootNotFound
    }
}
