//
//  NSMenuItem+ImageVisibility.swift
//  TablePro
//

import AppKit

internal extension NSMenuItem {
    /// From macOS 27 AppKit decides whether a menu item's image is drawn and hides symbol images by
    /// default, so an item whose image carries information the title does not repeat, a connection
    /// colour, an engine glyph, a Safe Mode level, loses that information silently. Those items say
    /// so here; a decorative image keeps the automatic behaviour, which is the intended new look.
    func setInformativeImage(_ image: NSImage?) {
        self.image = image
        if #available(macOS 27.0, *) {
            preferredImageVisibility = .visible
        }
    }
}
