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
struct MenuItemImageVisibilityTests {
    @Test("An informative image is set and, on macOS 27, marked visible")
    func informativeImageIsMarkedVisible() {
        let item = NSMenuItem(title: "Red", action: nil, keyEquivalent: "")
        let image = NSImage(size: NSSize(width: 12, height: 12))

        item.setInformativeImage(image)

        #expect(item.image === image)
        #if SDK_MACOS_27
        if #available(macOS 27.0, *) {
            #expect(item.preferredImageVisibility == .visible)
        }
        #endif
    }

    @Test("Clearing an informative image leaves no stale image behind")
    func clearingAnInformativeImage() {
        let item = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
        item.setInformativeImage(NSImage(size: NSSize(width: 12, height: 12)))

        item.setInformativeImage(nil)

        #expect(item.image == nil)
    }
}
