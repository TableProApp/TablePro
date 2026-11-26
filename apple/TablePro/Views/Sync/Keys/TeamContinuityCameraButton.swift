//
//  TeamContinuityCameraButton.swift
//  TablePro
//

import AppKit
import SwiftUI

// A pull-down whose menu Continuity Camera fills with the nearby iPhone's or iPad's Take Photo, so this Mac reads a
// code with no camera of its own (core ADR 0056, Pins).
internal struct TeamContinuityCameraButton: NSViewRepresentable {
    let title: String
    let onImage: (CGImage) -> Void

    func makeNSView(context: Context) -> TeamContinuityCameraPopUp {
        let button = TeamContinuityCameraPopUp(title: title)
        button.onImage = onImage
        return button
    }

    func updateNSView(_ button: TeamContinuityCameraPopUp, context: Context) {
        button.setTitle(title)
        button.onImage = onImage
    }
}

// AppKit on purpose: Continuity Camera fills a menu item named `NSMenuItem.importFromDeviceIdentifier` only when the
// first responder answers `validRequestor(forSendType:returnType:)` for an image, and the photo comes back through
// `NSServicesMenuRequestor`, neither of which SwiftUI offers on a button.
internal final class TeamContinuityCameraPopUp: NSPopUpButton, NSServicesMenuRequestor {
    var onImage: ((CGImage) -> Void)?

    init(title: String) {
        super.init(frame: .zero, pullsDown: true)
        bezelStyle = .push
        autoenablesItems = true
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let camera = NSMenuItem(title: String(localized: "Take Photo"), action: nil, keyEquivalent: "")
        camera.identifier = NSMenuItem.importFromDeviceIdentifier
        menu?.items = [titleItem, camera]
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var acceptsFirstResponder: Bool { true }

    // The menu reads the responder chain as it opens, so this button becomes first responder first.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func performClick(_ sender: Any?) {
        window?.makeFirstResponder(self)
        super.performClick(sender)
    }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if sendType == nil, let returnType, NSImage.imageTypes.contains(returnType.rawValue) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let image = NSImage(pasteboard: pasteboard),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return false }
        onImage?(cgImage)
        return true
    }

    func setTitle(_ title: String) {
        guard let item = menu?.items.first, item.title != title else { return }
        item.title = title
        setAccessibilityLabel(title)
    }
}
